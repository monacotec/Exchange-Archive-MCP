# Version: 0.2.0
# Pester 5 tests for the KQL query converter.

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\Lib\ConvertTo-KqlQuery.ps1')
}

Describe 'ConvertTo-KqlQuery' {

    It 'quotes field operators (Graph $search requires the whole value quoted)' {
        ConvertTo-KqlQuery -Query 'from:alice@x.com' | Should -Be '"from:alice@x.com"'
    }

    It 'rewrites after: to received>= and quotes it' {
        ConvertTo-KqlQuery -Query 'after:2024-01-01' | Should -Be '"received>=2024-01-01"'
    }

    It 'rewrites before: to received<= and quotes it' {
        ConvertTo-KqlQuery -Query 'before:2024-12-31' | Should -Be '"received<=2024-12-31"'
    }

    It 'rewrites has:attachment to hasAttachments:true and quotes it' {
        ConvertTo-KqlQuery -Query 'has:attachment' | Should -Be '"hasAttachments:true"'
    }

    It 'wraps multi-word free text in quotes' {
        ConvertTo-KqlQuery -Query 'quarterly board meeting' | Should -Be '"quarterly board meeting"'
    }

    It 'quotes single-word free text' {
        ConvertTo-KqlQuery -Query 'invoice' | Should -Be '"invoice"'
    }

    It 'quotes a mixed field+text query' {
        ConvertTo-KqlQuery -Query 'from:bob@x.com invoice' | Should -Be '"from:bob@x.com invoice"'
    }

    It 'combines multiple shortcuts in one query and quotes the result' {
        ConvertTo-KqlQuery -Query 'from:alice@x.com after:2024-01-01 has:attachment' |
            Should -Be '"from:alice@x.com received>=2024-01-01 hasAttachments:true"'
    }
}
