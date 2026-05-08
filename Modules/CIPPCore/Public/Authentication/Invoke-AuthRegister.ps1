function Invoke-AuthRegister {
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    try {
        $body = $Request.Body
        $email = $body.email
        $password = $body.password
        $name = $body.name

        if (-not $email -or -not $password -or -not $name) {
            return [HttpResponseContext]@{
                StatusCode = [System.Net.HttpStatusCode]::BadRequest
                Body       = @{ error = "Email, password, and name are required" } | ConvertTo-Json
            }
        }

        if ($password.Length -lt 8) {
            return [HttpResponseContext]@{
                StatusCode = [System.Net.HttpStatusCode]::BadRequest
                Body       = @{ error = "Password must be at least 8 characters" } | ConvertTo-Json
            }
        }

        $result = New-CippLocalUser -Email $email -Password $password -Name $name

        return [HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::OK
            Body       = $result | ConvertTo-Json
        }
    }
    catch {
        return [HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = @{ error = $_.Exception.Message } | ConvertTo-Json
        }
    }
}
