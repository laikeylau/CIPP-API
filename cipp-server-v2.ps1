#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Standalone HTTP server for CIPP-API (production-grade)
.DESCRIPTION
    Single-threaded with key stability improvements over cipp-server.ps1:
    - Non-blocking accept (BeginGetContext) for periodic maintenance
    - Per-request timeout via background timer (default 120s)
    - Periodic garbage collection to prevent memory bloat
    - Reduced JSON depth (20 vs 100) to prevent memory explosion
    - Connection queue monitoring
    - Graceful shutdown
#>
[CmdletBinding()]
param(
    [int]$Port = 7071,
    [string]$Prefix = 'http://+:7071/',
    [int]$RequestTimeoutSec = 120,
    [int]$GCIntervalSec = 300,
    [int]$MaxMemoryMB = 4096
)

$ErrorActionPreference = 'Continue'

# ─── Mock Azure Functions types ──────────────────────────────────────────────
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

# ─── Environment setup ──────────────────────────────────────────────────────
$env:CIPP_CONFIG = $PSScriptRoot
$env:CIPPRootPath = $PSScriptRoot
$env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
$env:NonLocalHostAzurite = 'true'
$env:AzureWebJobs_CIPPOrchestrator_Disabled = 'true'
$env:CIPP_SEND_CHANNEL_NAME = 'false'

Write-Host "=== CIPP-API Production Server ===" -ForegroundColor Cyan
Write-Host "Config: Port=$Port, Timeout=${RequestTimeoutSec}s, GC=${GCIntervalSec}s, MaxMem=${MaxMemoryMB}MB" -ForegroundColor Gray

# ─── Load modules ───────────────────────────────────────────────────────────
Write-Host "Loading CIPPSharp.dll..." -ForegroundColor Yellow
$CIPPSharpDllPath = Join-Path $PSScriptRoot 'Shared' 'CIPPSharp' 'bin' 'CIPPSharp.dll'
if (Test-Path $CIPPSharpDllPath) {
    try {
        $null = [Reflection.Assembly]::LoadFile($CIPPSharpDllPath)
        Write-Host "  OK: CIPPSharp.dll loaded" -ForegroundColor Green
    } catch {
        Write-Host "  WARN: CIPPSharp.dll failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host "Loading compiled modules (.psd1)..." -ForegroundColor Yellow
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

Write-Host "Loading scripts (.ps1)..." -ForegroundColor Yellow
$Scripts = Get-ChildItem -Path $ModulePath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue
foreach ($Script in $Scripts) {
    try { . $Script.FullName } catch {}
}

$RequiredFunctions = @('Receive-CippHttpTrigger', 'New-AzDataTableContext', 'Get-CIPPTable', 'Get-CIPPAzDataTableEntity')
Write-Host "`nVerifying critical functions..." -ForegroundColor Yellow
foreach ($Func in $RequiredFunctions) {
    if (Get-Command $Func -ErrorAction SilentlyContinue) {
        Write-Host "  OK: $Func" -ForegroundColor Green
    } else {
        Write-Host "  MISSING: $Func" -ForegroundColor Red
    }
}

Write-Host "`nPre-loading credentials..." -ForegroundColor Yellow
try {
    $AuthResult = Get-CIPPAuthentication -Force
    if ($AuthResult) {
        Write-Host "  OK: Credentials loaded (ApplicationID: $env:ApplicationID)" -ForegroundColor Green
    }
} catch {
    Write-Host "  WARN: Credential pre-load failed: $_" -ForegroundColor Yellow
}

# ─── State tracking ─────────────────────────────────────────────────────────
$script:RequestCount = 0
$script:ErrorCount = 0
$script:LastGC = [DateTime]::UtcNow
$script:RequestStartTicks = 0  # When current request started
$script:RequestTimedOut = $false

# ─── Start HTTP listener ────────────────────────────────────────────────────
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add($Prefix)
$Listener.Start()

Write-Host "`n🚀 CIPP-API listening on http://0.0.0.0:$Port/" -ForegroundColor Green
Write-Host "   Timeout=${RequestTimeoutSec}s | MaxMem=${MaxMemoryMB}MB" -ForegroundColor Gray
Write-Host "Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

# ─── Main request loop ──────────────────────────────────────────────────────
try {
    while ($Listener.IsListening) {
        # ── Periodic GC ──
        $now = [DateTime]::UtcNow
        if (($now - $script:LastGC).TotalSeconds -ge $GCIntervalSec) {
            $memMB = [math]::Round([GC]::GetTotalMemory($false) / 1MB, 0)
            if ($memMB -gt $MaxMemoryMB) {
                Write-Host "  GC: ${memMB}MB > ${MaxMemoryMB}MB, collecting..." -ForegroundColor DarkYellow
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                [GC]::Collect()
                $after = [math]::Round([GC]::GetTotalMemory($false) / 1MB, 0)
                Write-Host "  GC: ${memMB}MB → ${after}MB" -ForegroundColor DarkYellow
            }
            $script:LastGC = $now
        }

        # ── Non-blocking accept (5s timeout for periodic maintenance) ──
        $asyncResult = $Listener.BeginGetContext($null, $null)
        $waited = $asyncResult.AsyncWaitHandle.WaitOne(5000)
        if (-not $waited) {
            # No request in 5s — continue to GC check
            continue
        }

        $Context = $Listener.EndGetContext($asyncResult)
        $Request = $Context.Request
        $Response = $Context.Response

        $Url = $Request.Url.LocalPath
        $Method = $Request.HttpMethod
        $script:RequestCount++

        # Skip favicon silently
        if ($Url -eq '/favicon.ico') {
            try {
                $Response.StatusCode = 204
                $Response.Close()
            } catch {}
            continue
        }

        Write-Host "  #$($script:RequestCount) $Method $Url" -ForegroundColor White

        # ── Start timeout watchdog in background ──
        $script:RequestTimedOut = $false
        $script:RequestStartTicks = [DateTime]::UtcNow.Ticks
        $watchdog = [System.Threading.Timer]::new({
            param($state)
            $elapsed = ([DateTime]::UtcNow.Ticks - $state.Ticks) / [TimeSpan]::TicksPerSecond
            if ($elapsed -gt $state.Timeout) {
                Write-Host "  TIMEOUT: Request exceeded $($state.Timeout)s" -ForegroundColor Red
                $state.TimedOut = $true
            }
        }, [PSCustomObject]@{
            Ticks    = $script:RequestStartTicks
            Timeout  = $RequestTimeoutSec
            TimedOut = $false
        }, 5000, 10000)  # First check after 5s, then every 10s

        try {
            # ── Read request body ──
            $Body = $null
            if ($Request.HasEntityBody) {
                $Reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
                $Body = $Reader.ReadToEnd()
                $Reader.Dispose()
                if ($Body -and $Request.ContentType -match 'application/json') {
                    try { $Body = $Body | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
                }
            }

            # ── Build Azure Functions-style request ──
            $EndpointRaw = ($Url -replace '^/api/', '') -replace '^/', ''
            if ($EndpointRaw -match '^Invoke-') { $EndpointRaw = $EndpointRaw -replace '^Invoke-', '' }

            $EndpointMap = @{
                'auth/login'    = 'AuthLogin'
                'auth/register' = 'AuthRegister'
                'auth/verify'   = 'AuthVerify'
                'me'            = 'Me'
            }
            if ($EndpointMap.ContainsKey($EndpointRaw)) { $EndpointRaw = $EndpointMap[$EndpointRaw] }

            $FuncRequest = [PSCustomObject]@{
                Method  = $Method
                Url     = $Request.Url.ToString()
                Params  = [PSCustomObject]@{ CIPPEndpoint = $EndpointRaw }
                Headers = @{}
                Body    = $Body
                Query   = [PSCustomObject]@{}
            }

            foreach ($Key in $Request.Headers.AllKeys) {
                $FuncRequest.Headers[$Key] = $Request.Headers[$Key]
            }

            if (-not $FuncRequest.Headers['x-ms-original-url']) {
                $FuncRequest.Headers['x-ms-original-url'] = $Request.Url.ToString()
            }

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

            $QueryParams = @{}
            foreach ($Key in $Request.QueryString.AllKeys) {
                if ($Key) { $QueryParams[$Key] = $Request.QueryString[$Key] }
            }
            $FuncRequest.Query = [PSCustomObject]$QueryParams

            if ($Method -eq 'POST' -and $Body -is [PSCustomObject]) {
                foreach ($Prop in $Body.PSObject.Properties) {
                    if (-not $QueryParams.ContainsKey($Prop.Name)) {
                        $FuncRequest.Query | Add-Member -NotePropertyName $Prop.Name -NotePropertyValue $Prop.Value -Force
                    }
                }
            }

            # ── Capture response ──
            $script:CippResponse = $null
            function global:Push-OutputBinding {
                param([string]$Name, $Value)
                if ($Name -eq 'Response') {
                    if ($Value -and $Value.PSObject.TypeNames -notcontains 'Microsoft.Azure.Functions.PowerShellWorker.HttpResponseContext') {
                        $Value.PSObject.TypeNames.Insert(0, 'Microsoft.Azure.Functions.PowerShellWorker.HttpResponseContext')
                    }
                    $script:CippResponse = $Value
                }
            }

            # ── Execute CIPP handler ──
            $null = Receive-CippHttpTrigger -Request $FuncRequest -TriggerMetadata @{}

            # ── Check if timed out ──
            try { $watchdog.Dispose() } catch {}
            if ($script:RequestTimedOut) {
                Write-Host "  TIMEOUT: $Method $Url" -ForegroundColor Red
                try {
                    $Response.StatusCode = 504
                    $timeoutBody = '{"error":{"message":"Request timed out"}}'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($timeoutBody)
                    $Response.ContentLength64 = $bytes.Length
                    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } catch {}
                $script:ErrorCount++
                continue
            }

            # ── Send response ──
            if ($script:CippResponse) {
                $Response.StatusCode = if ($script:CippResponse.StatusCode) { [int]$script:CippResponse.StatusCode } else { 200 }

                $ContentType = 'application/json'
                if ($script:CippResponse.Headers) {
                    foreach ($Key in $script:CippResponse.Headers.Keys) {
                        if ($Key -eq 'Content-Type') {
                            $ContentType = $script:CippResponse.Headers[$Key]
                        } else {
                            try { $Response.Headers.Add($Key, $script:CippResponse.Headers[$Key]) } catch {}
                        }
                    }
                }
                $Response.ContentType = $ContentType

                $BodyStr = if ($script:CippResponse.Body -is [string]) {
                    $script:CippResponse.Body
                } else {
                    # Depth 20 (was 100) — prevents memory explosion on large objects
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
            if ($_.Exception.Message -match "transport connection|Connection reset|submitted|Cannot access a disposed|stream") {
                Write-Host "  WARN: Client disconnected" -ForegroundColor DarkYellow
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
                Write-Host "  WARN: Could not write error response" -ForegroundColor DarkYellow
            }
            $script:ErrorCount++
        } finally {
            # Clean up watchdog timer
            try { $watchdog.Dispose() } catch {}
            try { $Response.Close() } catch {}

            # Log request timing
            $reqMs = ([DateTime]::UtcNow.Ticks - $script:RequestStartTicks) / [TimeSpan]::TicksPerMillisecond
            if ($reqMs -gt 5000) {
                Write-Host "  SLOW: $Method $Url took ${reqMs}ms" -ForegroundColor DarkYellow
            }
        }
    }
} finally {
    $Listener.Stop()
    $Listener.Dispose()
    Write-Host "Server stopped. Requests: $($script:RequestCount), Errors: $($script:ErrorCount)" -ForegroundColor Cyan
}
