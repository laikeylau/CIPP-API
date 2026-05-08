function Invoke-AuthVerify {
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $authHeader = $Request.Headers.'Authorization'
    if ($authHeader -match '^Bearer\s+(.+)$') {
        $token = $Matches[1]
        $payload = Test-JWTToken -Token $token
        if ($payload) {
            return [HttpResponseContext]@{
                StatusCode = [System.Net.HttpStatusCode]::OK
                Body       = @{ valid = $true; email = $payload.email } | ConvertTo-Json
            }
        }
    }

    return [HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::Unauthorized
        Body       = @{ valid = $false } | ConvertTo-Json
    }
}
