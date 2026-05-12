#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Standalone HTTP server for CIPP-API (no Azure Functions host needed)
.DESCRIPTION
    Uses .NET HttpListener to serve CIPP-API requests natively.
    Loads CIPP modules and routes to Receive-CippHttpTrigger.
#>
[CmdletBinding()]
param(
    [int]$Port = 7071,
    [string]$Prefix = 'http://+:7071/'
)

$ErrorActionPreference = 'Continue'

# Mock Azure Functions types that CIPP expects
# Define in global namespace so [HttpResponseContext] casts work throughout CIPP modules
if (-not ([System.Management.Automation.PSTypeName]'HttpResponseContext').Type) {
    Add-Type -TypeDefinition @"
using System.Collections;
using System.Collections.Generic;
public class HttpResponseContext {
    public int StatusCode { get; set; } = 200;
    public IDictionary Headers { get; set; } = new Dictionary<string, string>();
    public object Body { get; set; }
    public bool EnableContentNegotiation { get; set; }
    public string ContentType { get; set; }
}
"@ -ErrorAction SilentlyContinue
}

# Set CIPP environment
$env:CIPP_CONFIG = $PSScriptRoot
$env:CIPPRootPath = $PSScriptRoot
$env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
$env:NonLocalHostAzurite = 'true'
$env:AzureWebJobs_CIPPOrchestrator_Disabled = 'true'
$env:CIPP_SEND_CHANNEL_NAME = 'false'

Write-Host "=== CIPP-API Standalone Server ===" -ForegroundColor Cyan

# Load CIPPSharp assembly (contains CIPP.TestDataCache, CIPPRestClient, CIPPTokenCache)
Write-Host "Loading CIPPSharp.dll..." -ForegroundColor Yellow
$CIPPSharpDllPath = Join-Path $PSScriptRoot 'Shared' 'CIPPSharp' 'bin' 'CIPPSharp.dll'
if (Test-Path $CIPPSharpDllPath) {
    try {
        $null = [Reflection.Assembly]::LoadFile($CIPPSharpDllPath)
        Write-Host "  OK: CIPPSharp.dll loaded (Types: $([CIPP.TestDataCache]::Count))" -ForegroundColor Green
    } catch {
        Write-Host "  WARN: CIPPSharp.dll failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "  WARN: CIPPSharp.dll not found at $CIPPSharpDllPath" -ForegroundColor DarkYellow
}

Write-Host "Loading compiled modules (.psd1)..." -ForegroundColor Yellow

# Step 1: Import compiled DLL modules first (via .psd1 manifests)
$PsdModules = @(
    'AzBobbyTables/3.5.1/AzBobbyTables.psd1',
    'DNSHealth/1.1.6/DNSHealth.psd1',
    'HuduAPI/2.4.9/HuduAPI.psd1',
    'PassPushPosh/1.3.2/PassPushPosh.psd1',
    'CIPPCore/CIPPCore.psd1',
    'CIPPDB/CIPPDB.psd1',
    'CIPPHTTP/CIPPHTTP.psd1',
    'CIPPAlerts/CIPPAlerts.psd1',
    'CIPPStandards/CIPPStandards.psd1',
    'CIPPTests/CIPPTests.psd1',
    'CippExtensions/CippExtensions.psd1',
    'CippLocalAuth/CippLocalAuth.psd1',
    'CIPPActivityTriggers/CIPPActivityTriggers.psd1'
)

$ModulePath = Join-Path $PSScriptRoot 'Modules'
foreach ($ModRel in $PsdModules) {
    $ModPath = Join-Path $ModulePath $ModRel
    if (Test-Path $ModPath) {
        try {
            Import-Module $ModPath -Force -ErrorAction Stop
            Write-Host "  OK: $ModRel" -ForegroundColor Green
        } catch {
            Write-Host "  WARN: $ModRel - $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}

# Step 2: Import any remaining .psm1 files not covered above
Write-Host "Loading script modules (.psm1)..." -ForegroundColor Yellow
$Modules = Get-ChildItem -Path $ModulePath -Filter '*.psm1' -Recurse
foreach ($Mod in $Modules) {
    try {
        Import-Module $Mod.FullName -Force -ErrorAction Stop
        Write-Host "  OK: $($Mod.BaseName)" -ForegroundColor Green
    } catch {
        Write-Host "  WARN: $($Mod.BaseName) - $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# Step 3: Dot-source standalone .ps1 scripts
Write-Host "Loading scripts (.ps1)..." -ForegroundColor Yellow
$Scripts = Get-ChildItem -Path $ModulePath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue
foreach ($Script in $Scripts) {
    try {
        . $Script.FullName
    } catch {
        # Ignore script load errors (using namespace issues etc.)
    }
}

# Verify critical functions exist
$RequiredFunctions = @('Receive-CippHttpTrigger', 'New-AzDataTableContext', 'Get-CIPPTable', 'Get-CIPPAzDataTableEntity')
Write-Host "`nVerifying critical functions..." -ForegroundColor Yellow
foreach ($Func in $RequiredFunctions) {
    if (Get-Command $Func -ErrorAction SilentlyContinue) {
        Write-Host "  OK: $Func" -ForegroundColor Green
    } else {
        Write-Host "  MISSING: $Func" -ForegroundColor Red
    }
}

# Pre-load credentials from storage (Key Vault / Azurite) so env vars are set before first request
Write-Host "`nPre-loading credentials..." -ForegroundColor Yellow
try {
    $AuthResult = Get-CIPPAuthentication -Force
    if ($AuthResult) {
        Write-Host "  OK: Credentials loaded (ApplicationID: $env:ApplicationID)" -ForegroundColor Green
    } else {
        Write-Host "  WARN: Could not load credentials - manual setup may be required" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  WARN: Credential pre-load failed: $_" -ForegroundColor Yellow
}

Write-Host "`nStarting HTTP listener on port $Port..." -ForegroundColor Green

# Create HTTP listener
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add($Prefix)
$Listener.Start()

Write-Host "CIPP-API listening on http://0.0.0.0:$Port/" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

try {
    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        $Request = $Context.Request
        $Response = $Context.Response

        $Url = $Request.Url.LocalPath
        $Method = $Request.HttpMethod
        Write-Host "$Method $Url" -ForegroundColor White
        $script:_reqStartTicks = [DateTime]::UtcNow.Ticks

        try {
            # Read request body
            $Body = $null
            if ($Request.HasEntityBody) {
                $Reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
                $Body = $Reader.ReadToEnd()
                $Reader.Dispose()
                # Parse JSON body
                if ($Body -and $Request.ContentType -match 'application/json') {
                    try { $Body = $Body | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
                }
            }

            # Build Azure Functions-style request object
            $EndpointRaw = ($Url -replace '^/api/', '') -replace '^/', ''

            # Strip Invoke- prefix if present (frontend sends /api/Invoke-ListTenants but router adds Invoke-)
            if ($EndpointRaw -match '^Invoke-') {
                $EndpointRaw = $EndpointRaw -replace '^Invoke-', ''
            }

            # Map shorthand auth endpoints to full CIPP function names
            $EndpointMap = @{
                'auth/login'    = 'AuthLogin'
                'auth/register' = 'AuthRegister'
                'auth/verify'   = 'AuthVerify'
                'me'            = 'Me'
            }
            if ($EndpointMap.ContainsKey($EndpointRaw)) {
                $EndpointRaw = $EndpointMap[$EndpointRaw]
            }

            $FuncRequest = [PSCustomObject]@{
                Method  = $Method
                Url     = $Request.Url.ToString()
                Params  = [PSCustomObject]@{
                    CIPPEndpoint = $EndpointRaw
                }
                Headers = @{}
                Body    = $Body
                Query   = [PSCustomObject]@{}
            }

            # Copy headers
            foreach ($Key in $Request.Headers.AllKeys) {
                $FuncRequest.Headers[$Key] = $Request.Headers[$Key]
            }

            # Inject Azure-style x-ms-original-url header (needed by CIPP setup functions)
            if (-not $FuncRequest.Headers['x-ms-original-url']) {
                $FuncRequest.Headers['x-ms-original-url'] = $Request.Url.ToString()
            }

            # Inject local dev auth headers (mock Azure Static Web Apps auth)
            if (-not $FuncRequest.Headers['x-ms-client-principal']) {
                $LocalUser = @{
                    auth_typ   = 'aad'
                    name_typ   = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'
                    role_typ   = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'
                    claims     = @(
                        @{ typ = 'http://schemas.microsoft.com/identity/claims/tenantid'; val = 'local-dev' }
                        @{ typ = 'http://schemas.microsoft.com/identity/claims/objectidentifier'; val = 'local-dev-oid' }
                        @{ typ = 'name'; val = 'Local Admin' }
                        @{ typ = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'; val = 'superadmin' }
                        @{ typ = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'; val = 'authenticated' }
                    )
                    userRoles  = @('superadmin', 'authenticated')
                }
                $FuncRequest.Headers['x-ms-client-principal'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($LocalUser | ConvertTo-Json -Compress -Depth 5)))
                $FuncRequest.Headers['x-ms-client-principal-idp'] = 'aad'
                $FuncRequest.Headers['x-ms-client-principal-name'] = 'local-admin@cipp.local'
            }

            # Copy query parameters
            $QueryParams = @{}
            foreach ($Key in $Request.QueryString.AllKeys) {
                if ($Key) { $QueryParams[$Key] = $Request.QueryString[$Key] }
            }
            $FuncRequest.Query = [PSCustomObject]$QueryParams

            # Merge POST body parameters into Query so functions that read $Request.Query work with POST requests
            if ($Method -eq 'POST' -and $Body -is [PSCustomObject]) {
                foreach ($Prop in $Body.PSObject.Properties) {
                    if (-not $QueryParams.ContainsKey($Prop.Name)) {
                        $FuncRequest.Query | Add-Member -NotePropertyName $Prop.Name -NotePropertyValue $Prop.Value -Force
                    }
                }
            }

            # Create response capture
            $script:CippResponse = $null

            # Define Push-OutputBinding mock
            function global:Push-OutputBinding {
                param([string]$Name, $Value)
                if ($Name -eq 'Response') {
                    # Ensure PSTypeName matches what Azure Functions host provides,
                    # so New-CippCoreRequest's Where-Object filter works correctly
                    if ($Value -and $Value.PSObject.TypeNames -notcontains 'Microsoft.Azure.Functions.PowerShellWorker.HttpResponseContext') {
                        $Value.PSObject.TypeNames.Insert(0, 'Microsoft.Azure.Functions.PowerShellWorker.HttpResponseContext')
                    }
                    $script:CippResponse = $Value
                }
            }

            # Call the CIPP HTTP trigger
            $null = Receive-CippHttpTrigger -Request $FuncRequest -TriggerMetadata @{}

            # Send response
            if ($script:CippResponse) {
                $Response.StatusCode = if ($script:CippResponse.StatusCode) { [int]$script:CippResponse.StatusCode } else { 200 }

                $ContentType = 'application/json'
                if ($script:CippResponse.Headers) {
                    foreach ($Key in $script:CippResponse.Headers.Keys) {
                        if ($Key -eq 'Content-Type') {
                            $ContentType = $script:CippResponse.Headers[$Key]
                        } else {
                            $Response.Headers.Add($Key, $script:CippResponse.Headers[$Key])
                        }
                    }
                }
                $Response.ContentType = $ContentType

                $BodyStr = if ($script:CippResponse.Body -is [string]) {
                    $script:CippResponse.Body
                } else {
                    ConvertTo-Json -InputObject $script:CippResponse.Body -Depth 20 -Compress
                }
                $ResponseBytes = [System.Text.Encoding]::UTF8.GetBytes($BodyStr)
                $Response.ContentLength64 = $ResponseBytes.Length
                $Response.OutputStream.Write($ResponseBytes, 0, $ResponseBytes.Length)
            } else {
                $Response.StatusCode = 200
                $OK = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
                $Response.ContentLength64 = $OK.Length
                $Response.OutputStream.Write($OK, 0, $OK.Length)
            }
        } catch {
            # Check if this is a connection error that should not crash the server
            if ($_.Exception.Message -match "transport connection|Connection reset|submitted|Cannot access a disposed|stream" ) {
                Write-Host "  WARN: Client disconnected: $($_.Exception.Message)" -ForegroundColor DarkYellow
                try { $Response.Close() } catch {}
                continue
            }
            try {
                Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
                $Response.StatusCode = 500
                $ErrBody = @{ error = @{ message = $_.Exception.Message } } | ConvertTo-Json -Compress
                $ErrBytes = [System.Text.Encoding]::UTF8.GetBytes($ErrBody)
                $Response.ContentLength64 = $ErrBytes.Length
                $Response.OutputStream.Write($ErrBytes, 0, $ErrBytes.Length)
            } catch {
                Write-Host "  WARN: Could not write error response: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        } finally {
            try { $Response.Close() } catch {}
            # Slow request logging (> 15s)
            if ($script:_reqStartTicks) {
                $elapsed = [math]::Round(([DateTime]::UtcNow.Ticks - $script:_reqStartTicks) / 1e7, 1)
                if ($elapsed -gt 15) {
                    Write-Host "  SLOW: $Method $Url took ${elapsed}s" -ForegroundColor Yellow
                }
            }
            # Memory management: check after each request
            $script:_reqCount = ($script:_reqCount | ForEach-Object { $_ }) + 1
            if ($script:_reqCount % 50 -eq 0) {
                $memMB = [math]::Round([GC]::GetTotalMemory($false) / 1MB, 0)
                Write-Host "  MEM: ${memMB}MB after $($script:_reqCount) requests" -ForegroundColor DarkGray
                if ($memMB -gt 2048) {
                    Write-Host "  GC: Forcing collection..." -ForegroundColor DarkYellow
                    [GC]::Collect()
                    [GC]::WaitForPendingFinalizers()
                    [GC]::Collect()
                    $after = [math]::Round([GC]::GetTotalMemory($false) / 1MB, 0)
                    Write-Host "  GC: ${memMB}MB → ${after}MB" -ForegroundColor DarkYellow
                }
            }
        }
    }
} finally {
    $Listener.Stop()
    $Listener.Dispose()
    Write-Host "Server stopped." -ForegroundColor Yellow
}
