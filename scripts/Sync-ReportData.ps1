<#
.SYNOPSIS
    Directly sync CIPP report database cache for specified data types

.DESCRIPTION
    Bypasses the orchestrator (which doesn't work on Linux standalone) and directly
    calls the Set-CIPPDBCache* functions to populate the CippReportingDB table.

.PARAMETER TenantFilter
    The tenant domain to sync data for

.PARAMETER Types
    Array of cache types to sync. Valid values:
    'Mailboxes', 'Users', 'Groups', 'Guests', 'Devices', 'Organization',
    'CASMailboxes', 'MailboxUsage', 'OneDriveUsage', 'SharePointSiteUsage',
    'ManagedDevices', 'ConditionalAccessPolicies', 'Roles', 'Domains',
    'LicenseOverview', 'ServicePrincipals', 'Apps'
    
    Default: 'Mailboxes'

.EXAMPLE
    ./Sync-ReportData.ps1 -TenantFilter 'contoso.onmicrosoft.com'
    Sync mailbox data only

.EXAMPLE
    ./Sync-ReportData.ps1 -TenantFilter 'contoso.onmicrosoft.com' -Types 'Mailboxes','Users','Groups'
    Sync multiple data types
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantFilter,

    [string[]]$Types = @('Mailboxes')
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
if (-not $env:AzureWebJobsStorage) {
    $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
}
if (-not $env:NonLocalHostAzurite) {
    $env:NonLocalHostAzurite = 'true'
}

$TotalStart = Get-Date
$SuccessCount = 0
$FailedCount = 0

Write-Host "=== CIPP Report Data Sync ===" -ForegroundColor Cyan
Write-Host "Tenant: $TenantFilter"
Write-Host "Types: $($Types -join ', ')"
Write-Host ""

foreach ($Type in $Types) {
    $TypeStart = Get-Date
    $FunctionName = "Set-CIPPDBCache$Type"
    
    Write-Host "[$Type] Starting sync..." -ForegroundColor Yellow
    
    try {
        $Function = Get-Command -Name $FunctionName -ErrorAction SilentlyContinue
        if (-not $Function) {
            throw "Function $FunctionName not found"
        }
        
        & $FunctionName -TenantFilter $TenantFilter -Types 'None'
        
        $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
        Write-Host "[$Type] Completed in $([math]::Round($Elapsed, 1))s" -ForegroundColor Green
        $SuccessCount++
    } catch {
        $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
        Write-Host "[$Type] FAILED after $([math]::Round($Elapsed, 1))s: $($_.Exception.Message)" -ForegroundColor Red
        $FailedCount++
    }
}

$TotalElapsed = ((Get-Date) - $TotalStart).TotalSeconds
Write-Host ""
Write-Host "=== Sync Complete ===" -ForegroundColor Cyan
Write-Host "Total: $($Types.Count) types, $SuccessCount succeeded, $FailedCount failed"
Write-Host "Elapsed: $([math]::Round($TotalElapsed, 1))s"
