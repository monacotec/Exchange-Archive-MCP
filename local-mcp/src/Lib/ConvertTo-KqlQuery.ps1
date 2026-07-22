# Version: 0.3.0
# Translate a casual query into KQL acceptable by Graph $search on mail.
#
# Rules:
#   - after:YYYY-MM-DD / before:YYYY-MM-DD shortcuts rewrite to received>= / received<=.
#   - has:attachment(s) rewrites to hasAttachments:true.
#   - The final value is ALWAYS wrapped in double quotes. Graph's $search requires the
#     whole value double-quoted, even for field operators (subject:, from:, received>=, ...)
#     -- the operators are still recognised inside the quotes. Graph only inconsistently
#     tolerates unquoted bare terms (it accepts "unsubscribe" but rejects "zzqx...9999"),
#     so quoting unconditionally is the only reliable contract.
#
# Hardening (security baseline section 4):
#   - Hard cap on input length (defeats DoS via giant strings and prompt-injected blobs).
#   - Reject ASCII control chars and Unicode bidi-override characters; these can smuggle
#     payloads past the field-operator regex or visually mislead an audit reviewer.

Set-StrictMode -Version Latest

# Maximum accepted raw query length. Keep at or below Graph's effective $search limit.
$script:KqlMaxQueryLength = 2000

# Build the disallowed-character regex from codepoints so the source file
# stays printable-ASCII (no embedded literal control or bidi chars).
#   C0 controls           : U+0000..U+001F
#   DEL                   : U+007F
#   Bidi override (LRE..RLO/PDF): U+202A..U+202E
#   Bidi isolate           : U+2066..U+2069
$script:KqlDisallowedCharClass = '[' +
    [char]0x00 + '-' + [char]0x1F +
    [char]0x7F +
    [char]0x202A + '-' + [char]0x202E +
    [char]0x2066 + '-' + [char]0x2069 +
    ']'

function ConvertTo-KqlQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Query)

    if ($Query.Length -gt $script:KqlMaxQueryLength) {
        throw "Query exceeds maximum length of $script:KqlMaxQueryLength characters."
    }

    if ([regex]::IsMatch($Query, $script:KqlDisallowedCharClass)) {
        throw 'Query contains disallowed control or bidi-override characters.'
    }

    $q = $Query.Trim()
    if (-not $q) { return '""' }

    $q = [regex]::Replace($q, '(?i)\bafter:(\d{4}-\d{2}-\d{2})\b',  'received>=$1')
    $q = [regex]::Replace($q, '(?i)\bbefore:(\d{4}-\d{2}-\d{2})\b', 'received<=$1')
    $q = [regex]::Replace($q, '(?i)\bhas:attachments?\b',           'hasAttachments:true')

    # Always quote. Field operators are recognised inside the quotes; bare terms
    # and phrases are treated as term/phrase matches. Escape any embedded quotes.
    return ('"{0}"' -f ($q -replace '"', '\"'))
}
