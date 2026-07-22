# Version: 0.2.0

Set-StrictMode -Version Latest

function Invoke-GetArchiveAttachment {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$MessageId,
        [Parameter(Mandatory)][string]$AttachmentId
    )
    $uri = "https://graph.microsoft.com/v1.0/me/messages/$MessageId/attachments/$AttachmentId"
    $resp = Invoke-McpGraph -Uri $uri
    $att = $resp.Value
    if ($att.'@odata.type' -ne '#microsoft.graph.fileAttachment') {
        return [PSCustomObject]@{
            id          = $att.id
            name        = $att.name
            contentType = $att.contentType
            size        = $att.size
            kind        = $att.'@odata.type'
            note        = 'Non-file attachments (item/reference) are not written to disk.'
        }
    }
    if (-not (Test-Path $Ctx.OutputsDir)) {
        New-Item -ItemType Directory -Path $Ctx.OutputsDir -Force | Out-Null
    }
    $safeName = ($att.name -replace '[\\/:*?"<>|]', '_')
    $stamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $outPath  = Join-Path $Ctx.OutputsDir ("{0}_{1}" -f $stamp, $safeName)
    $bytes    = [Convert]::FromBase64String($att.contentBytes)
    [System.IO.File]::WriteAllBytes($outPath, $bytes)
    return [PSCustomObject]@{
        id          = $att.id
        name        = $att.name
        contentType = $att.contentType
        size        = $att.size
        path        = $outPath
    }
}
