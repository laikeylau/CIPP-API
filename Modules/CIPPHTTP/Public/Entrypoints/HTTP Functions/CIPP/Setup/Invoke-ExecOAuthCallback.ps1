function Invoke-ExecOAuthCallback {
    # CIPP OAuth callback handler for authorization code flow
    $Code = $Request.Query.code
    $State = $Request.Query.state
    $Error = $Request.Query.error

    if ($Error) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Redirect
            Headers    = @{ Location = "/cipp/setup?error=$Error" }
        })
        return
    }

    if (!$Code) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = "Missing authorization code"
        })
        return
    }

    try {
        $TenantId = $env:TenantID ?? "2b2ccf22-1af7-4ef4-a191-ad9b9a3b5de1"
        $AppId = $env:ApplicationID
        $AppSecret = $env:ApplicationSecret

        if (!$AppId -or !$AppSecret) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = "Application credentials not configured"
            })
            return
        }

        $RedirectUri = "https://$($Request.Headers.'x-ms-original-url' -replace '.*//([^/]+)/.*','$1')/api/ExecOAuthCallback"
        if ($Request.Headers.'x-ms-original-url') {
            $hostHeader = $Request.Headers.'x-ms-original-url' -replace 'https?://([^/]+)/.*','$1'
            $RedirectUri = "https://$hostHeader/api/ExecOAuthCallback"
        }

        # Exchange authorization code for tokens
        $TokenBody = @{
            grant_type    = "authorization_code"
            client_id     = $AppId
            client_secret = $AppSecret
            code          = $Code
            redirect_uri  = "https://mtm.cxty.de/api/ExecOAuthCallback"
            scope         = "https://graph.microsoft.com/.default offline_access"
        }

        $TokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $TokenBody -ContentType "application/x-www-form-urlencoded"

        if ($TokenResponse.refresh_token) {
            # Store in DevSecrets
            $DevSecrets = Get-CIPPTable -TableName 'DevSecrets'
            $Secret = Get-CIPPAzDataTableEntity @DevSecrets -Filter "PartitionKey eq 'Secret' and RowKey eq 'Secret'"
            if ($Secret) {
                $Secret.RefreshToken = $TokenResponse.refresh_token
                Update-AzDataTableEntity @DevSecrets -Entity $Secret
            }

            # Also set env vars for this session
            $env:RefreshToken = $TokenResponse.refresh_token

            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Redirect
                Headers    = @{ Location = "/cipp/setup?success=true" }
                Body       = "Authentication successful! Refresh token stored."
            })
        } else {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = "Failed to get refresh token: $($TokenResponse | ConvertTo-Json -Compress)"
            })
        }
    } catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = "Error: $($_.Exception.Message)"
        })
    }
}
