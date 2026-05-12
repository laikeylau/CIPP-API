<#
.SYNOPSIS
    Directly sync CIPP report database cache for specified data types

.DESCRIPTION
    Bypasses the orchestrator (which doesn't work on Linux standalone) and directly
    calls the Set-CIPPDBCache* functions to populate the CippReportingDB table.

    For Permissions, CalendarPermissions, and Rules types, this script directly
    calls New-ExoBulkRequest with -AsApp and stores results, bypassing
    Start-CIPPOrchestrator entirely.

.PARAMETER TenantFilter
    The tenant domain to sync data for

.PARAMETER Types
    Array of cache types to sync. Valid values:
    'Mailboxes', 'Users', 'Groups', 'Guests', 'Devices', 'Organization',
    'CASMailboxes', 'MailboxUsage', 'OneDriveUsage', 'SharePointSiteUsage',
    'ManagedDevices', 'ConditionalAccessPolicies', 'Roles', 'Domains',
    'LicenseOverview', 'ServicePrincipals', 'Apps',
    'Permissions', 'CalendarPermissions', 'Rules'
    
    Default: 'Mailboxes'

.PARAMETER BatchSize
    Batch size for permission/calendar/rules processing. Default: 50

.EXAMPLE
    ./Sync-ReportData.ps1 -TenantFilter 'contoso.onmicrosoft.com'
    Sync mailbox data only

.EXAMPLE
    ./Sync-ReportData.ps1 -TenantFilter 'contoso.onmicrosoft.com' -Types 'Mailboxes','Permissions','CalendarPermissions'
    Sync mailboxes, permissions, and calendar permissions

.EXAMPLE
    ./Sync-ReportData.ps1 -TenantFilter 'contoso.onmicrosoft.com' -Types 'All'
    Sync all data types including permissions, calendar, and rules
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantFilter,

    [string[]]$Types = @('Mailboxes'),

    [int]$BatchSize = 50
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

# Expand 'All' to all available types
if ($Types -contains 'All') {
    $Types = @('Mailboxes', 'Permissions', 'CalendarPermissions', 'Rules')
}

$TotalStart = Get-Date
$SuccessCount = 0
$FailedCount = 0

Write-Host "=== CIPP Report Data Sync ===" -ForegroundColor Cyan
Write-Host "Tenant: $TenantFilter"
Write-Host "Types: $($Types -join ', ')"
Write-Host ""

# ─── Standard cache types (use Set-CIPPDBCache* functions) ──────────────────
$StandardTypes = @('Mailboxes', 'Users', 'Groups', 'Guests', 'Devices', 'Organization',
    'CASMailboxes', 'MailboxUsage', 'OneDriveUsage', 'SharePointSiteUsage',
    'ManagedDevices', 'ConditionalAccessPolicies', 'Roles', 'Domains',
    'LicenseOverview', 'ServicePrincipals', 'Apps')

# ─── Permission-related types (use direct EXO calls with -AsApp) ─────────────
$PermissionTypes = @('Permissions', 'CalendarPermissions', 'Rules')

foreach ($Type in $Types) {
    $TypeStart = Get-Date

    if ($StandardTypes -contains $Type) {
        # ── Standard type: call Set-CIPPDBCache* directly ────────────────────
        $FunctionName = "Set-CIPPDBCache$Type"
        Write-Host "[$Type] Starting sync..." -ForegroundColor Yellow

        try {
            $Function = Get-Command -Name $FunctionName -ErrorAction SilentlyContinue
            if (-not $Function) {
                throw "Function $FunctionName not found"
            }

            # Only Set-CIPPDBCacheMailboxes accepts -Types; other functions don't
            if ($Type -eq 'Mailboxes') {
                & $FunctionName -TenantFilter $TenantFilter -Types 'None'
            } else {
                & $FunctionName -TenantFilter $TenantFilter
            }

            $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
            Write-Host "[$Type] Completed in $([math]::Round($Elapsed, 1))s" -ForegroundColor Green
            $SuccessCount++
        } catch {
            $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
            Write-Host "[$Type] FAILED after $([math]::Round($Elapsed, 1))s: $($_.Exception.Message)" -ForegroundColor Red
            $FailedCount++
        }

    } elseif ($PermissionTypes -contains $Type) {
        # ── Permission type: direct EXO batch calls with -AsApp ──────────────
        Write-Host "[$Type] Starting direct batch sync..." -ForegroundColor Yellow

        try {
            # Step 1: Ensure mailbox data exists
            Write-Host "  Loading mailbox data..." -ForegroundColor Gray
            $MailboxItems = Get-CIPPDbItem -TenantFilter $TenantFilter -Type 'Mailboxes' | Where-Object { $_.RowKey -ne 'Mailboxes-Count' }
            if (-not $MailboxItems) {
                throw "No mailbox data found. Run 'Mailboxes' sync first."
            }

            $AllMailboxData = @($MailboxItems | ForEach-Object {
                    $Mb = $_.Data | ConvertFrom-Json
                    [PSCustomObject]@{
                        Id                  = $Mb.Id
                        UPN                 = $Mb.UPN
                        GrantSendOnBehalfTo = $Mb.GrantSendOnBehalfTo
                    }
                })
            $AllMailboxUPNs = @($AllMailboxData | Select-Object -ExpandProperty UPN)
            Write-Host "  Found $($AllMailboxUPNs.Count) mailboxes" -ForegroundColor Gray

            # Step 2: Build batches
            $TotalBatches = [Math]::Ceiling($AllMailboxUPNs.Count / $BatchSize)
            Write-Host "  Created $TotalBatches batches (batch size: $BatchSize)" -ForegroundColor Gray

            # Step 3: Process batches directly
            $AllResults = [System.Collections.Generic.List[object]]::new()

            for ($i = 0; $i -lt $AllMailboxUPNs.Count; $i += $BatchSize) {
                $BatchUPNs = @($AllMailboxUPNs[$i..[Math]::Min($i + $BatchSize - 1, $AllMailboxUPNs.Count - 1)])
                $BatchNumber = [Math]::Floor($i / $BatchSize) + 1
                Write-Host "  Processing batch $BatchNumber/$TotalBatches ($($BatchUPNs.Count) mailboxes)..." -ForegroundColor Gray

                try {
                    switch ($Type) {
                        'Permissions' {
                            # Build bulk requests: Get-MailboxPermission + Get-RecipientPermission per mailbox
                            $ExoBulkRequests = foreach ($MailboxUPN in $BatchUPNs) {
                                @{
                                    CmdletInput = @{
                                        CmdletName = 'Get-MailboxPermission'
                                        Parameters = @{ Identity = $MailboxUPN }
                                    }
                                }
                                @{
                                    CmdletInput = @{
                                        CmdletName = 'Get-RecipientPermission'
                                        Parameters = @{ Identity = $MailboxUPN }
                                    }
                                }
                            }

                            $MailboxPermissions = New-ExoBulkRequest -cmdletArray @($ExoBulkRequests) -tenantid $TenantFilter -ReturnWithCommand $true -AsApp

                            # Normalize MailboxPermission results
                            if ($MailboxPermissions['Get-MailboxPermission']) {
                                foreach ($Perm in $MailboxPermissions['Get-MailboxPermission']) {
                                    $AccessStr = if ($Perm.AccessRights -is [array]) { $Perm.AccessRights -join ',' } else { $Perm.AccessRights }
                                    $AllResults.Add([PSCustomObject]@{
                                            id           = "MBP-$($Perm.Identity)-$($Perm.User)-$AccessStr"
                                            Identity     = $Perm.Identity
                                            User         = $Perm.User
                                            AccessRights = $Perm.AccessRights
                                            IsInherited  = $Perm.IsInherited
                                            Deny         = $Perm.Deny
                                        })
                                }
                            }

                            # Normalize RecipientPermission results
                            if ($MailboxPermissions['Get-RecipientPermission']) {
                                foreach ($Perm in $MailboxPermissions['Get-RecipientPermission']) {
                                    $UserVal = if ($Perm.Trustee) { $Perm.Trustee } else { $Perm.User }
                                    $AccessStr = if ($Perm.AccessRights -is [array]) { $Perm.AccessRights -join ',' } else { $Perm.AccessRights }
                                    $AllResults.Add([PSCustomObject]@{
                                            id           = "RCP-$($Perm.Identity)-$UserVal-$AccessStr"
                                            Identity     = $Perm.Identity
                                            User         = $UserVal
                                            AccessRights = $Perm.AccessRights
                                            IsInherited  = $Perm.IsInherited
                                            Deny         = $Perm.Deny
                                        })
                                }
                            }

                            # Normalize SendOnBehalf permissions from mailbox metadata
                            $MailboxIdentityLookup = @{}
                            foreach ($MappedMailbox in ($AllMailboxData | Where-Object { $_.Id -and $_.UPN })) {
                                $MailboxIdentityLookup[[string]$MappedMailbox.Id] = [string]$MappedMailbox.UPN
                            }
                            foreach ($Mailbox in ($AllMailboxData | Where-Object { $_.GrantSendOnBehalfTo -and ($BatchUPNs -contains $_.UPN) })) {
                                foreach ($Delegate in (@($Mailbox.GrantSendOnBehalfTo) | Where-Object { $_ -and $MailboxIdentityLookup.ContainsKey([string]$_) })) {
                                    $DelegateUPN = $MailboxIdentityLookup[[string]$Delegate]
                                    $AllResults.Add([PSCustomObject]@{
                                            id           = "SOB-$($Mailbox.UPN)-$DelegateUPN"
                                            Identity     = $Mailbox.UPN
                                            User         = $DelegateUPN
                                            AccessRights = @('SendOnBehalf')
                                            IsInherited  = $false
                                            Deny         = $false
                                        })
                                }
                            }
                        }
                        'CalendarPermissions' {
                            # Phase 1: Get calendar folder names
                            $FolderStatsRequests = foreach ($MailboxUPN in $BatchUPNs) {
                                @{
                                    CmdletInput   = @{
                                        CmdletName = 'Get-MailboxFolderStatistics'
                                        Parameters = @{
                                            Identity    = $MailboxUPN
                                            FolderScope = 'Calendar'
                                        }
                                    }
                                    OperationGuid = $MailboxUPN
                                }
                            }

                            $FolderStatsResults = New-ExoBulkRequest -tenantid $TenantFilter -cmdletArray @($FolderStatsRequests) -AsApp
                            $FolderNameMap = @{}
                            foreach ($Result in $FolderStatsResults) {
                                if (-not $Result.error -and $Result.OperationGuid -and $Result.name) {
                                    $FolderNameMap[$Result.OperationGuid] = $Result.name
                                }
                            }

                            # Phase 2: Get calendar permissions
                            $PermissionRequests = foreach ($MailboxUPN in $BatchUPNs) {
                                $FolderName = $FolderNameMap[$MailboxUPN]
                                if ($FolderName) {
                                    @{
                                        CmdletInput   = @{
                                            CmdletName = 'Get-MailboxFolderPermission'
                                            Parameters = @{
                                                Identity = "$($MailboxUPN):\$($FolderName)"
                                            }
                                        }
                                        OperationGuid = $MailboxUPN
                                    }
                                }
                            }

                            if ($PermissionRequests) {
                                $PermissionResults = New-ExoBulkRequest -tenantid $TenantFilter -cmdletArray @($PermissionRequests) -useSystemMailbox $true -AsApp
                                foreach ($Perm in $PermissionResults) {
                                    if (-not $Perm.error) {
                                        $AccessStr = if ($Perm.AccessRights -is [array]) { $Perm.AccessRights -join ',' } else { $Perm.AccessRights }
                                        $AllResults.Add([PSCustomObject]@{
                                                id           = "CAL-$($Perm.Identity)-$($Perm.User)-$AccessStr"
                                                Identity     = $Perm.Identity
                                                User         = $Perm.User
                                                AccessRights = $Perm.AccessRights
                                                FolderName   = $Perm.FolderName
                                            })
                                    }
                                }
                            }
                        }
                        'Rules' {
                            # Get mailbox rules
                            $RuleRequests = foreach ($MailboxUPN in $BatchUPNs) {
                                @{
                                    CmdletInput = @{
                                        CmdletName = 'Get-InboxRule'
                                        Parameters = @{ Mailbox = $MailboxUPN }
                                    }
                                }
                            }

                            $RuleResults = New-ExoBulkRequest -cmdletArray @($RuleRequests) -tenantid $TenantFilter -AsApp
                            foreach ($Rule in $RuleResults) {
                                if (-not $Rule.error) {
                                    $AllResults.Add($Rule)
                                }
                            }
                        }
                    }
                } catch {
                    Write-Host "    Batch $BatchNumber error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # Step 4: Store results
            Write-Host "  Storing $($AllResults.Count) $Type entries..." -ForegroundColor Gray

            if ($AllResults.Count -gt 0) {
                switch ($Type) {
                    'Permissions' {
                        $AllResults | Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'MailboxPermissions' -AddCount
                    }
                    'CalendarPermissions' {
                        $AllResults | Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'CalendarPermissions' -AddCount
                    }
                    'Rules' {
                        $AllResults | Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'MailboxRules' -AddCount
                    }
                }
            }

            $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
            Write-Host "[$Type] Completed in $([math]::Round($Elapsed, 1))s — $($AllResults.Count) entries stored" -ForegroundColor Green
            $SuccessCount++
        } catch {
            $Elapsed = ((Get-Date) - $TypeStart).TotalSeconds
            Write-Host "[$Type] FAILED after $([math]::Round($Elapsed, 1))s: $($_.Exception.Message)" -ForegroundColor Red
            $FailedCount++
        }
    } else {
        Write-Host "[$Type] Unknown type, skipping" -ForegroundColor Yellow
        $FailedCount++
    }
}

$TotalElapsed = ((Get-Date) - $TotalStart).TotalSeconds
Write-Host ""
Write-Host "=== Sync Complete ===" -ForegroundColor Cyan
Write-Host "Total: $($Types.Count) types, $SuccessCount succeeded, $FailedCount failed"
Write-Host "Elapsed: $([math]::Round($TotalElapsed, 1))s"
