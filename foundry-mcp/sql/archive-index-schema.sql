/*
    archive-index-schema.sql
    Version: 1.0.0

    Schema for the archive message index: per-item metadata harvested from
    Purview eDiscovery report exports (the only data path that reaches the
    In-Place Archive -- Graph's mail API cannot, see
    docs/online-archive-graph-findings.md).

    Loaded by scripts/Import-ArchiveSearchToSql.ps1. That loader goes straight
    to eDiscovery app-only, so it is NOT subject to the MCP tool's 100-items-
    per-call cap: the report CSV carries every row of a search (up to the
    500-item export ceiling, which the loader handles by auto-bisecting the
    date range into windows).

    Conventions (house standard):
      - Run with sqlcmd -I (QUOTED_IDENTIFIER ON). Filtered indexes and
        computed-column writes fail with error 1934 under the OFF default.
      - Idempotent at STATEMENT granularity: the table guard does not wrap the
        index guards, so a partially applied batch is repaired by re-running.
      - Text is NVARCHAR throughout. Subjects carry em-dashes and curly quotes;
        the loader writes its input files UTF-8 *with BOM* and the verify pass
        runs a mojibake tripwire (archive.vMojibakeTripwire).

    Design notes:
      - Natural key is the internet message id: it survives re-export and is
        stable across the archive/primary copies of the same message, which is
        what makes cross-store dedupe possible.
      - Noise classification lives in a VIEW, not a stored column, so the rules
        can be revised without reloading (they were revised once already --
        helpdesk tickets tag as '#HLPDSK<digits>', not the word 'helpdesk').
      - StoreKind comes from the report's 'Location sub type' column
        (ArchiveMailBox / PrimaryMailBox), the only reliable archive-vs-primary
        discriminator in the export -- folder paths look identical across stores
        (both render '/Top of Information Store/...').
*/

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'archive')
    EXEC (N'CREATE SCHEMA archive');
GO

/* ── Load provenance ──────────────────────────────────────────────────────── */
IF OBJECT_ID('archive.LoadRun', 'U') IS NULL
BEGIN
    CREATE TABLE archive.LoadRun (
        LoadRunId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoadRun PRIMARY KEY,
        Tag             NVARCHAR(128)   NOT NULL,
        KqlQuery        NVARCHAR(2000)  NOT NULL,
        WindowStart     DATE            NULL,
        WindowEnd       DATE            NULL,
        MatchedCount    INT             NULL,   -- eDiscovery estimate for the window
        RetrievedCount  INT             NULL,   -- rows parsed out of the report
        SearchId        NVARCHAR(64)     NULL,
        ExportOpId      NVARCHAR(64)     NULL,
        StartedUtc      DATETIME2(0)    NOT NULL CONSTRAINT DF_LoadRun_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc    DATETIME2(0)    NULL,
        Status          NVARCHAR(32)    NOT NULL CONSTRAINT DF_LoadRun_Status  DEFAULT N'running',
        Note            NVARCHAR(1000)  NULL
    );
END
GO

/* ── Message index ────────────────────────────────────────────────────────── */
IF OBJECT_ID('archive.Message', 'U') IS NULL
BEGIN
    CREATE TABLE archive.Message (
        MessageId       NVARCHAR(400)   NOT NULL,   -- internet message id (natural key)
        ItemId          NVARCHAR(512)   NULL,       -- immutable id (Outlook/Graph)
        Subject         NVARCHAR(1000)  NULL,
        SenderAddress   NVARCHAR(320)   NULL,
        ReceivedUtc     DATETIME2(0)    NULL,
        FolderPath      NVARCHAR(1000)  NULL,
        StoreKind       NVARCHAR(32)    NULL,       -- ArchiveMailBox | PrimaryMailBox | unknown
        SizeBytes       BIGINT          NULL,
        FirstSeenRunId  INT             NULL,
        LastSeenRunId   INT             NULL,
        FirstLoadedUtc  DATETIME2(0)    NOT NULL CONSTRAINT DF_Message_FirstLoaded DEFAULT SYSUTCDATETIME(),
        LastLoadedUtc   DATETIME2(0)    NOT NULL CONSTRAINT DF_Message_LastLoaded  DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Message PRIMARY KEY (MessageId)
    );
END
GO

/* Staging: truncated and refilled per window, then merged. Deliberately
   constraint-free so a malformed row fails the MERGE, not the bulk insert. */
IF OBJECT_ID('archive.MessageStaging', 'U') IS NULL
BEGIN
    CREATE TABLE archive.MessageStaging (
        MessageId       NVARCHAR(400)   NULL,
        ItemId          NVARCHAR(512)   NULL,
        Subject         NVARCHAR(1000)  NULL,
        SenderAddress   NVARCHAR(320)   NULL,
        ReceivedUtc     DATETIME2(0)    NULL,
        FolderPath      NVARCHAR(1000)  NULL,
        StoreKind       NVARCHAR(32)    NULL,
        SizeBytes       BIGINT          NULL
    );
END
GO

/* ── Indexes: guarded individually (not inside the table block) ───────────── */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Message_ReceivedUtc'
               AND object_id = OBJECT_ID('archive.Message'))
    CREATE INDEX IX_Message_ReceivedUtc ON archive.Message (ReceivedUtc DESC)
        INCLUDE (Subject, SenderAddress, FolderPath, StoreKind);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Message_SenderAddress'
               AND object_id = OBJECT_ID('archive.Message'))
    CREATE INDEX IX_Message_SenderAddress ON archive.Message (SenderAddress)
        INCLUDE (ReceivedUtc, Subject);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Message_Subject'
               AND object_id = OBJECT_ID('archive.Message'))
    CREATE INDEX IX_Message_Subject ON archive.Message (Subject)
        INCLUDE (ReceivedUtc, SenderAddress, StoreKind);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoadRun_Tag'
               AND object_id = OBJECT_ID('archive.LoadRun'))
    CREATE INDEX IX_LoadRun_Tag ON archive.LoadRun (Tag, StartedUtc DESC);
GO

/* ── Classification view ──────────────────────────────────────────────────── */
/* NoiseReason is derived, never stored: the rules get revised as new artifact
   shapes turn up, and a view means revision costs nothing. Order matters --
   the first matching predicate wins. */
CREATE OR ALTER VIEW archive.vMessageClassified AS
SELECT
    m.*,
    CASE
        /* Helpdesk tickets: the id is '#HLPDSK<digits>'. Matching the word
           'helpdesk' misses these entirely (learned the hard way). */
        WHEN m.Subject LIKE N'%#HLPDSK[0-9]%'                       THEN N'helpdesk ticket'
        WHEN m.Subject LIKE N'Accepted:%'
          OR m.Subject LIKE N'Declined:%'
          OR m.Subject LIKE N'Tentative:%'
          OR m.Subject LIKE N'Canceled:%'
          OR m.Subject LIKE N'Cancelled:%'                          THEN N'meeting response'
        WHEN m.FolderPath LIKE N'%/Calendar%'                       THEN N'calendar item'
        WHEN m.FolderPath LIKE N'%Deleted Items%'
          OR m.FolderPath LIKE N'%Recoverable Items%'               THEN N'deleted/recoverable copy'
        /* Reply/forward: anchored so 'Freddie: ...' style subjects don't match. */
        WHEN m.Subject LIKE N'RE:%'  OR m.Subject LIKE N'RE :%'
          OR m.Subject LIKE N'FW:%'  OR m.Subject LIKE N'FWD:%'     THEN N'reply/forward thread'
        ELSE NULL
    END AS NoiseReason
FROM archive.Message AS m;
GO

/* The signal: original announcements/messages with the artifacts stripped. */
CREATE OR ALTER VIEW archive.vMessageSignal AS
SELECT * FROM archive.vMessageClassified WHERE NoiseReason IS NULL;
GO

/* ── Verification helpers (content-level, server-side) ────────────────────── */
/* UTF-8-read-as-1252 tripwire: 'â‚¬' (U+00E2 U+20AC) cannot occur in real mail
   subjects but is the signature of a BOM-less UTF-8 load. Any row here means
   the load path regressed -- fix the encoding, do not "clean" the data. */
CREATE OR ALTER VIEW archive.vMojibakeTripwire AS
SELECT MessageId, Subject, FolderPath, SenderAddress
FROM archive.Message
WHERE Subject       LIKE N'%' + NCHAR(226) + NCHAR(8364) + N'%'
   OR FolderPath    LIKE N'%' + NCHAR(226) + NCHAR(8364) + N'%'
   OR SenderAddress LIKE N'%' + NCHAR(226) + NCHAR(8364) + N'%';
GO

/* Coverage by store and year -- the shape of what has actually been indexed. */
CREATE OR ALTER VIEW archive.vCoverage AS
SELECT
    COALESCE(StoreKind, N'unknown')        AS StoreKind,
    YEAR(ReceivedUtc)                      AS ReceivedYear,
    COUNT(*)                               AS Messages,
    SUM(CASE WHEN c.NoiseReason IS NULL THEN 1 ELSE 0 END) AS SignalMessages,
    MIN(ReceivedUtc)                       AS OldestUtc,
    MAX(ReceivedUtc)                       AS NewestUtc
FROM archive.vMessageClassified AS c
GROUP BY COALESCE(StoreKind, N'unknown'), YEAR(ReceivedUtc);
GO

/* ── MERGE staging -> Message ─────────────────────────────────────────────── */
/* Dedupe happens twice: inside the source (a message present in BOTH the
   archive and primary copy arrives as two rows with one message id) and
   against the target. Newest ReceivedUtc wins; an ArchiveMailBox row is
   preferred as the survivor when timestamps tie, since this index exists to
   describe the archive. */
CREATE OR ALTER PROCEDURE archive.usp_MergeStaging
    @LoadRunId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ;WITH ranked AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY MessageId
                   ORDER BY CASE WHEN StoreKind = N'ArchiveMailBox' THEN 0 ELSE 1 END,
                            ReceivedUtc DESC
               ) AS rn
        FROM archive.MessageStaging
        WHERE MessageId IS NOT NULL AND LTRIM(RTRIM(MessageId)) <> N''
    )
    MERGE archive.Message AS tgt
    USING (SELECT * FROM ranked WHERE rn = 1) AS src
        ON tgt.MessageId = src.MessageId
    WHEN MATCHED THEN UPDATE SET
        tgt.ItemId        = COALESCE(src.ItemId, tgt.ItemId),
        tgt.Subject       = COALESCE(src.Subject, tgt.Subject),
        tgt.SenderAddress = COALESCE(src.SenderAddress, tgt.SenderAddress),
        tgt.ReceivedUtc   = COALESCE(src.ReceivedUtc, tgt.ReceivedUtc),
        tgt.FolderPath    = COALESCE(src.FolderPath, tgt.FolderPath),
        tgt.StoreKind     = COALESCE(src.StoreKind, tgt.StoreKind),
        tgt.SizeBytes     = COALESCE(src.SizeBytes, tgt.SizeBytes),
        tgt.LastSeenRunId = @LoadRunId,
        tgt.LastLoadedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (MessageId, ItemId, Subject, SenderAddress, ReceivedUtc, FolderPath,
         StoreKind, SizeBytes, FirstSeenRunId, LastSeenRunId)
        VALUES
        (src.MessageId, src.ItemId, src.Subject, src.SenderAddress, src.ReceivedUtc,
         src.FolderPath, src.StoreKind, src.SizeBytes, @LoadRunId, @LoadRunId);

    SELECT
        (SELECT COUNT(*) FROM archive.MessageStaging)                          AS StagedRows,
        (SELECT COUNT(*) FROM archive.Message WHERE FirstSeenRunId = @LoadRunId) AS InsertedRows,
        (SELECT COUNT(*) FROM archive.Message WHERE LastSeenRunId  = @LoadRunId
                                                AND FirstSeenRunId <> @LoadRunId) AS UpdatedRows;
END
GO
