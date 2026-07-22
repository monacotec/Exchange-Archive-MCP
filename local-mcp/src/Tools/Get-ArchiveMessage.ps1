# Version: 0.2.0

Set-StrictMode -Version Latest

function Invoke-GetArchiveMessage {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$MessageId,
        [string]$BodyFormat = 'text'
    )
    $extra = @{}
    if ($BodyFormat -eq 'text') { $extra['Prefer'] = 'outlook.body-content-type="text"' }
    $uri = "https://graph.microsoft.com/v1.0/me/messages/$MessageId" +
           '?$select=id,subject,from,toRecipients,ccRecipients,bccRecipients,receivedDateTime,sentDateTime,hasAttachments,internetMessageHeaders,body,parentFolderId,conversationId'
    $resp = Invoke-McpGraph -Uri $uri -ExtraHeaders $extra
    $m = $resp.Value

    $attachments = @()
    if ($m.hasAttachments) {
        $aResp = Invoke-McpGraph -Uri "https://graph.microsoft.com/v1.0/me/messages/$MessageId/attachments?`$select=id,name,contentType,size,isInline"
        $attachments = $aResp.Value.value
    }

    return [PSCustomObject]@{
        id               = $m.id
        subject          = $m.subject
        from             = $m.from.emailAddress
        to               = ($m.toRecipients  | ForEach-Object { $_.emailAddress })
        cc               = ($m.ccRecipients  | ForEach-Object { $_.emailAddress })
        bcc              = ($m.bccRecipients | ForEach-Object { $_.emailAddress })
        received         = $m.receivedDateTime
        sent             = $m.sentDateTime
        parentFolderId   = $m.parentFolderId
        conversationId   = $m.conversationId
        bodyType         = $m.body.contentType
        body             = $m.body.content
        headers          = $m.internetMessageHeaders
        attachments      = $attachments
    }
}
