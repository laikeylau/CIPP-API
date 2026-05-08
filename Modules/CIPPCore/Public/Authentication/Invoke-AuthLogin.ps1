function Invoke-AuthLogin {
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    try {
        $body = $Request.Body
        $email = $body.email
        $password = $body.password

        if (-not $email -or -not $password) {
            return [HttpResponseContext]@{
                StatusCode = [System.Net.HttpStatusCode]::BadRequest
                Body       = @{ error = "Email and password are required" } | ConvertTo-Json
            }
        }

        $result = Confirm-CippLocalLogin -Email $email -Password $password

        return [HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::OK
            Body       = $result | ConvertTo-Json
        }
    }
    catch {
        return [HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::Unauthorized
            Body       = @{ error = $_.Exception.Message } | ConvertTo-Json
        }
    }
}
