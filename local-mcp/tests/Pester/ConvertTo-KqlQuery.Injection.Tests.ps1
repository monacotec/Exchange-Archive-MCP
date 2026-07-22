# Version: 0.1.0
# Adversarial / fuzz coverage for ConvertTo-KqlQuery.
# Owed by LOCAL-MCP-PLAN.md Phase 4 section 4 (security baseline section 4).
#
# These tests assert the translator either:
#   (a) safely passes through legitimate field-operator usage, OR
#   (b) rejects inputs that could smuggle additional clauses, control bytes,
#       bidi-override visual spoofs, or oversized payloads past the regex.

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\Lib\ConvertTo-KqlQuery.ps1')
}

Describe 'ConvertTo-KqlQuery - injection and abuse cases' {

    Context 'Length cap' {
        It 'throws when input exceeds the configured max length' {
            $tooLong = 'a' * ($script:KqlMaxQueryLength + 1)
            { ConvertTo-KqlQuery -Query $tooLong } | Should -Throw -ExpectedMessage '*maximum length*'
        }

        It 'accepts input exactly at the configured max length' {
            $atLimit = 'a' * $script:KqlMaxQueryLength
            { ConvertTo-KqlQuery -Query $atLimit } | Should -Not -Throw
        }
    }

    Context 'Control-character rejection' {
        It 'rejects embedded newline (LF) -- defeats second-clause smuggling' {
            $payload = "from:alice@x.com" + [char]0x0A + "from:attacker@evil.com"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }

        It 'rejects embedded carriage return (CR)' {
            $payload = "subject:foo" + [char]0x0D + "subject:bar"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }

        It 'rejects embedded NUL byte' {
            $payload = "invoice" + [char]0x00 + "rm -rf"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }

        It 'rejects embedded tab' {
            $payload = "from:alice@x.com" + [char]0x09 + "extra"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }

        It 'rejects DEL (0x7F)' {
            $payload = "test" + [char]0x7F + "del"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }
    }

    Context 'Unicode bidi-override rejection' {
        It 'rejects U+202E (right-to-left override) -- visual audit-log spoofing' {
            $payload = "from:alice@x.com" + [char]0x202E + "from:attacker@evil.com"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }

        It 'rejects U+2066 (left-to-right isolate)' {
            $payload = "subject:foo" + [char]0x2066 + "bar"
            { ConvertTo-KqlQuery -Query $payload } | Should -Throw -ExpectedMessage '*control or bidi*'
        }
    }

    Context 'OData-style injection in field-operator tails' {
        It "does not break out of a date value with embedded apostrophe" {
            # Apostrophe is allowed (legitimate in some field values) but the
            # rewrite regex for received>= is anchored on the YYYY-MM-DD shape,
            # so a malformed date stays as free text and gets phrase-quoted.
            $payload = "received>=2026-01-01' OR '1'='1"
            $result  = ConvertTo-KqlQuery -Query $payload
            $result | Should -Match "^"".*OR.*""$"
        }

        It 'leaves an apostrophe inside a quoted free-text phrase untouched' {
            $result = ConvertTo-KqlQuery -Query "Q1 board's meeting"
            $result | Should -Be '"Q1 board''s meeting"'
        }
    }

    Context 'Field-operator regex robustness' {
        It 'recognises mixed-case operator prefixes (case-insensitive)' {
            ConvertTo-KqlQuery -Query 'FROM:alice@x.com'  | Should -Be '"FROM:alice@x.com"'
            ConvertTo-KqlQuery -Query 'After:2026-01-01' | Should -Be '"received>=2026-01-01"'
            ConvertTo-KqlQuery -Query 'Has:Attachments'  | Should -Be '"hasAttachments:true"'
        }

        It 'handles has:attachment and has:attachments equivalently' {
            ConvertTo-KqlQuery -Query 'has:attachment'  | Should -Be '"hasAttachments:true"'
            ConvertTo-KqlQuery -Query 'has:attachments' | Should -Be '"hasAttachments:true"'
        }

        It 'wraps multi-word free text in quotes and escapes embedded double-quotes' {
            $result = ConvertTo-KqlQuery -Query 'they said "go"'
            $result | Should -Be '"they said \"go\""'
        }

        It 'wraps a mixed field+text query in outer quotes (Graph parses field ops inside the quotes)' {
            $result = ConvertTo-KqlQuery -Query 'from:bob@x.com invoice'
            # Graph requires the whole $search value quoted; the field operator is
            # still recognised inside the quotes, so this is "from:bob AND invoice".
            $result | Should -Be '"from:bob@x.com invoice"'
        }
    }

    Context 'Boundary cases' {
        It 'returns an empty-phrase placeholder for whitespace-only input' {
            ConvertTo-KqlQuery -Query '   ' | Should -Be '""'
        }

        It 'quotes a single free-text token' {
            ConvertTo-KqlQuery -Query 'invoice' | Should -Be '"invoice"'
        }

        It 'accepts a long but legal multi-word phrase up to the cap' {
            $phrase = (1..50 | ForEach-Object { 'word' + $_ }) -join ' '
            $result = ConvertTo-KqlQuery -Query $phrase
            $result | Should -Match '^".*"$'
        }
    }
}
