<#
.SYNOPSIS
    Sync Dashboard v2 data to CIPP report database for all tenants
    (Users, Guests, Groups, Devices, SecureScore, MFAState, LicenseOverview)

.DESCRIPTION
    Bypasses the ExecCIPPDBCache orchestrator (which doesn't work on Linux standalone)
    and directly calls Set-CIPPDBCache* functions to populate the CippReportingDB.

    When run without -TenantFilter, automatically discovers all active tenants
    from the CIPP Tenants table and syncs each one.

.PARAMETER TenantFilter
    Optional. The tenant domain to sync. If omitted, syncs all active tenants.

.PARAMETER MaxErrorCount
    Maximum GraphErrorCount before skipping a tenant (default: 50)

.EXAMPLE
    # Sync all tenants
    ./Sync-DashboardData.ps1

    # Sync single tenant
    ./Sync-DashboardData.ps1 -TenantFilter 'demfre05outlook.onmicrosoft.com'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantFilter,
    [Parameter(Mandatory = $false)]
    [int]$MaxErrorCount = 50
)

$ErrorActionPreference = 'Continue'

# Load required modules
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ApiRoot = Split-Path -Parent $ScriptDir

Import-Module "$ApiRoot/Modules/AzBobbyTables/3.5.1/AzBobbyTables.psd1" -Force
Import-Module "$ApiRoot/Modules/CIPPDB" -Force
Import-Module "$ApiRoot/Modules/CIPPCore" -Force
Import-Module "$ApiRoot/Modules/CIPPHTTP" -Force

# Set environment variables (same as cipp-server.ps1)
if (-not $env:CIPPRootPath) {
    $env:CIPPRootPath = $ApiRoot
}
if (-not $env:AzureWebJobsStorage) {
    $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
}
if (-not $env:NonLocalHostAzurite) {
    $env:NonLocalHostAzurite = 'true'
}

# Dashboard data types to sync
$DashboardTypes = @(
    @{ Name = 'Users';                  Fn = 'Set-CIPPDBCacheUsers' }
    @{ Name = 'Guests';                 Fn = 'Set-CIPPDBCacheGuests' }
    @{ Name = 'Groups';                 Fn = 'Set-CIPPDBCacheGroups' }
    @{ Name = 'Devices';                Fn = 'Set-CIPPDBCacheDevices' }
    @{ Name = 'SecureScore';            Fn = 'Set-CIPPDBCacheSecureScore' }
    @{ Name = 'MFAState';               Fn = 'Set-CIPPDBCacheMFAState' }
    @{ Name = 'LicenseOverview';        Fn = 'Set-CIPPDBCacheLicenseOverview' }
)

# ─── Discover tenants ───────────────────────────────────────────────────────
if ($TenantFilter) {
    $Tenants = @([PSCustomObject]@{
        RowKey           = $TenantFilter
        defaultDomainName = $TenantFilter
        displayName       = $TenantFilter
        GraphErrorCount   = 0
    })
} else {
    Write-Host "=== Discovering tenants from CIPP database ===" -ForegroundColor Cyan
    $TenantsTable = Get-CIPPTable -TableName 'Tenants'
    $AllTenants = Get-CIPPAzDataTableEntity @TenantsTable
    $Tenants = @($AllTenants | Where-Object {
        $_.RowKey -ne 'Failed' -and
        $_.defaultDomainName -and
        [int]$_.GraphErrorCount -lt $MaxErrorCount
    })
    Write-Host "Found $($Tenants.Count) active tenant(s) (GraphErrorCount < $MaxErrorCount)" -ForegroundColor White
    foreach ($t in $Tenants) {
        Write-Host "  • $($t.displayName) ($($t.defaultDomainName)) — Errors: $($t.GraphErrorCount)" -ForegroundColor Gray
    }
    Write-Host ""
}

if ($Tenants.Count -eq 0) {
    Write-Host "No tenants to sync. Exiting." -ForegroundColor Yellow
    exit 0
}

# ─── Sync each tenant ───────────────────────────────────────────────────────
$GlobalStart = Get-Date
$GlobalSuccess = 0
$GlobalFailed = 0
$TenantResults = @()

foreach ($Tenant in $Tenants) {
    $TenantDomain = $Tenant.defaultDomainName
    $TenantName = $Tenant.displayName
    $TenantStart = Get-Date

    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Tenant: $TenantName ($TenantDomain)" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    $TenantSuccess = 0
    $TenantFailed = 0

    foreach ($TypeInfo in $DashboardTypes) {
        $Type = $TypeInfo.Name
        $FunctionName = $TypeInfo.Fn
        $TypeStart = Get-Date

        Write-Host "  [$Type] Syncing..." -ForegroundColor Yellow -NoNewline

        try {
            $Function = Get-Command -Name $FunctionName -ErrorAction SilentlyContinue
            if (-not $Function) {
                throw "Function $FunctionName not found"
            }

            & $FunctionName -TenantFilter $TenantDomain

            $CountRow = Get-CIPPDbItem -TenantFilter $TenantDomain -Type $Type -Count
            $DataCount = if ($CountRow) { $CountRow.DataCount } else { '?' }
            $Elapsed = [math]::Round(((Get-Date) - $TypeStart).TotalSeconds, 1)

            Write-Host "`r  [$Type] ✅ $DataCount records (${Elapsed}s)              " -ForegroundColor Green
            $TenantSuccess++
        } catch {
            $Elapsed = [math]::Round(((Get-Date) - $TypeStart).TotalSeconds, 1)
            Write-Host "`r  [$Type] ❌ FAILED (${Elapsed}s): $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))              " -ForegroundColor Red
            $TenantFailed++
        }

        Start-Sleep -Seconds 1
    }

    $TenantElapsed = [math]::Round(((Get-Date) - $TenantStart).TotalSeconds, 1)
    Write-Host "  ── Tenant done: $TenantSuccess/$($DashboardTypes.Count) types in ${TenantElapsed}s" -ForegroundColor $(if ($TenantFailed -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ""

    $GlobalSuccess += $TenantSuccess
    $GlobalFailed += $TenantFailed
    $TenantResults += [PSCustomObject]@{
        Tenant  = $TenantName
        Domain  = $TenantDomain
        Success = $TenantSuccess
        Failed  = $TenantFailed
        Elapsed = "${TenantElapsed}s"
    }
}

# ─── Summary ────────────────────────────────────────────────────────────────
$GlobalElapsed = [math]::Round(((Get-Date) - $GlobalStart).TotalSeconds, 1)

Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "DONE — $($Tenants.Count) tenant(s), $GlobalSuccess/$($Tenants.Count * $DashboardTypes.Count) types OK, $GlobalFailed failed, ${GlobalElapsed}s total" -ForegroundColor $(if ($GlobalFailed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
$TenantResults | Format-Table -AutoSize | Out-String | Write-Host
