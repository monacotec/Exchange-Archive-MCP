@{
    RootModule        = ''
    ModuleVersion     = '0.3.2'
    GUID              = 'a7d2f1b4-9e6c-4a3f-bd21-7f0e9c4c5a01'
    Author            = 'Jeff Monaco'
    CompanyName       = 'GI Partners'
    Copyright         = '(c) 2026 GI Partners. All rights reserved.'
    Description       = 'Model Context Protocol server for Exchange Online archive mailboxes (delegated Graph access via Microsoft.Graph.Authentication).'
    PowerShellVersion = '7.2'
    RequiredModules   = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
    )
    PrivateData       = @{
        PSData = @{
            Tags       = @('MCP','Exchange','Graph','Archive')
            ProjectUri = ''
        }
        Mcp = @{
            ProtocolVersion = '2025-06-18'
            ServerName      = 'exchange-archive-local'
        }
    }
}
