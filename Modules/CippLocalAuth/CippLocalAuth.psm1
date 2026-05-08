# ============================================
# CIPP Local Authentication Module
# ============================================
# Self-contained user authentication for Linux deployment.
# No Azure AD / SWA dependency.
# Users are stored in Azurite Table Storage.
# Passwords are hashed with SHA256+salt.
# JWT tokens are generated with HMAC-SHA256.

$Script:JWTSecret = $null
$Script:JWTSecretFile = Join-Path $env:CIPPRootPath 'Config/.jwt-secret'

function Get-JWTSecret {
    if ($Script:JWTSecret) { return $Script:JWTSecret }

    if (Test-Path $Script:JWTSecretFile) {
        $Script:JWTSecret = [System.IO.File]::ReadAllText($Script:JWTSecretFile).Trim()
    } else {
        # Generate a random secret
        $bytes = New-Object byte[] 64
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $Script:JWTSecret = [Convert]::ToBase64String($bytes)
        [System.IO.File]::WriteAllText($Script:JWTSecretFile, $Script:JWTSecret)
        Write-Information "Generated new JWT secret"
    }
    return $Script:JWTSecret
}

function ConvertTo-SecureHash {
    param([string]$Password, [string]$Salt)
    $combined = $Salt + $Password
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToBase64String($hash)
}

function New-JWTToken {
    param(
        [string]$Email,
        [string]$UserId,
        [string[]]$Roles
    )

    $secret = Get-JWTSecret
    $header = @{ alg = "HS256"; typ = "JWT" } | ConvertTo-Json -Compress
    $now = [DateTimeOffset]::UtcNow
    $payload = @{
        sub   = $UserId
        email = $Email
        roles = $Roles
        iat   = [long]($now.ToUnixTimeSeconds())
        exp   = [long]($now.AddHours(24).ToUnixTimeSeconds())
    } | ConvertTo-Json -Compress

    # Base64url encode
    $headerB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    # HMAC-SHA256 signature
    $dataToSign = "$headerB64.$payloadB64"
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($secret))
    $signature = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dataToSign))).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    return "$headerB64.$payloadB64.$signature"
}

function Test-JWTToken {
    param([string]$Token)

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -ne 3) { return $null }

        $secret = Get-JWTSecret

        # Verify signature
        $dataToVerify = "$($parts[0]).$($parts[1])"
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($secret))
        $expectedSig = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dataToVerify))).TrimEnd('=').Replace('+', '-').Replace('/', '_')

        if ($expectedSig -ne $parts[2]) {
            Write-Warning "JWT signature mismatch"
            return $null
        }

        # Decode payload
        $payloadB64 = $parts[1]
        $mod = $payloadB64.Length % 4
        if ($mod -gt 0) { $payloadB64 += ('=' * (4 - $mod)) }
        $payloadB64 = $payloadB64.Replace('-', '+').Replace('_', '/')

        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadB64))
        $payload = $payloadJson | ConvertFrom-Json

        # Check expiration
        $exp = [DateTimeOffset]::FromUnixTimeSeconds($payload.exp)
        if ($exp -lt [DateTimeOffset]::UtcNow) {
            Write-Warning "JWT token expired"
            return $null
        }

        return $payload
    }
    catch {
        Write-Warning "JWT validation failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-CippLocalUsers {
    $Table = Get-CIPPTable -tablename 'LocalUsers'
    return Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'User'"
}

function Get-CippLocalUser {
    param([string]$Email)

    $Table = Get-CIPPTable -tablename 'LocalUsers'
    $user = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'User' and RowKey eq '$Email'"
    return $user
}

function New-CippLocalUser {
    param(
        [string]$Email,
        [string]$Password,
        [string]$Name
    )

    $Table = Get-CIPPTable -tablename 'LocalUsers'

    # Check if user already exists
    $existing = Get-CippLocalUser -Email $Email
    if ($existing) {
        throw "User already exists"
    }

    # Check if this is the first user (becomes admin)
    $allUsers = Get-CippLocalUsers
    $isFirstUser = ($null -eq $allUsers) -or (@($allUsers).Count -eq 0)
    $role = if ($isFirstUser) { 'admin' } else { 'readonly' }

    # Hash password
    $salt = [Convert]::ToBase64String([byte[]](1..16 | ForEach-Object { Get-Random -Maximum 256 }))
    $hash = ConvertTo-SecureHash -Password $Password -Salt $salt

    $user = [PSCustomObject]@{
        PartitionKey = 'User'
        RowKey       = $Email.ToLower()
        Email        = $Email.ToLower()
        Name         = $Name
        Role         = $Role
        PasswordHash = $hash
        Salt         = $salt
        CreatedAt    = [DateTime]::UtcNow.ToString('o')
    }

    Add-CIPPAzDataTableEntity @Table -Entity $user -Force

    # Generate token
    $token = New-JWTToken -Email $Email -UserId $Email -Roles @($Role, 'authenticated')

    return @{
        token = $token
        user  = @{
            email = $Email
            name  = $Name
            role  = $Role        # singular — frontend AuthGuard checks user.role
            roles = @($Role, 'authenticated')
        }
    }
}

function Confirm-CippLocalLogin {
    param(
        [string]$Email,
        [string]$Password
    )

    $user = Get-CippLocalUser -Email $Email
    if (-not $user) {
        throw "Invalid email or password"
    }

    $hash = ConvertTo-SecureHash -Password $Password -Salt $user.Salt
    if ($hash -ne $user.PasswordHash) {
        throw "Invalid email or password"
    }

    # Generate token
    $roles = @($user.Role, 'authenticated')
    $token = New-JWTToken -Email $Email -UserId $Email -Roles $roles

    return @{
        token = $token
        user  = @{
            email = $user.Email
            name  = $user.Name
            role  = $user.Role      # singular — frontend AuthGuard checks user.role
            roles = $roles
        }
    }
}
