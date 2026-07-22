# Version: 0.2.0
# Resolve signed-in user identity for audit context.
# Relies on the Microsoft.Graph.Authentication session managed by Connect-McpGraph.

Set-StrictMode -Version Latest

function Resolve-UserContext {
    [CmdletBinding()]
    param()
    $resp = Invoke-McpGraph -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,displayName,mail'
    $me = $resp.Value
    return [PSCustomObject]@{
        Id          = $me.id
        Upn         = $me.userPrincipalName
        DisplayName = $me.displayName
        Mail        = $me.mail
    }
}
