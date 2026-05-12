<#
.SYNOPSIS
    Pre-cache all CIPP report data for all tenants (comprehensive)
.DESCRIPTION
    Bypasses ExecCIPPDBCache orchestrator and directly calls Set-CIPPDBCache* functions.
    Organized by category for selective sync. Covers Identity, Exchange, SharePoint,
    Intune, Security, Copilot, and more.

    Without -Categories, syncs ALL categories. Use -Categories to pick specific ones.

.PARAMETER TenantFilter
    Optional. Single tenant domain. If omitted, syncs all active tenants.

.PARAMETER Categories
    Optional. Array of category names to sync. Default: all.
    Valid: Dashboard, Identity, Exchange, SharePoint, Intune, Security, Copilot, PIM, Compliance, Other

.PARAMETER MaxErrorCount
    Max GraphErrorCount before skipping tenant (default: 50)

.PARAMETER DryRun
    Show what would be synced without executing

.EXAMPLE
    # Sync everything for all tenants
    ./Sync-AllCache.ps1

    # Sync only Exchange and Identity
    ./Sync-AllCache.ps1 -Categories Exchange,Identity

    # Single tenant, dry run
    ./Sync-AllCache.ps1 -TenantFilter 'contoso.com' -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantFilter,
    [Parameter(Mandatory = $false)]
    [string[]]$Categories,
    [Parameter(Mandatory = $false)]
    [int]$MaxErrorCount = 50,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ─── Load modules ────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ApiRoot = Split-Path -Parent $ScriptDir

Import-Module "$ApiRoot/Modules/AzBobbyTables/3.5.1/AzBobbyTables.psd1" -Force
Import-Module "$ApiRoot/Modules/CIPPDB" -Force
Import-Module "$ApiRoot/Modules/CIPPCore" -Force
Import-Module "$ApiRoot/Modules/CIPPHTTP" -Force

if (-not $env:CIPPRootPath) { $env:CIPPRootPath = $ApiRoot }
if (-not $env:AzureWebJobsStorage) {
    $env:AzureWebJobsStorage = 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;'
}
if (-not $env:NonLocalHostAzurite) { $env:NonLocalHostAzurite = 'true' }

# ─── Category definitions ────────────────────────────────────────────────────
$AllCategories = [ordered]@{
    Dashboard = @{
        Description = 'Dashboard v2 widgets'
        Types = @(
            @{ Name = 'Users';                  Fn = 'Set-CIPPDBCacheUsers' }
            @{ Name = 'Guests';                 Fn = 'Set-CIPPDBCacheGuests' }
            @{ Name = 'Groups';                 Fn = 'Set-CIPPDBCacheGroups' }
            @{ Name = 'Devices';                Fn = 'Set-CIPPDBCacheDevices' }
            @{ Name = 'SecureScore';            Fn = 'Set-CIPPDBCacheSecureScore' }
            @{ Name = 'MFAState';               Fn = 'Set-CIPPDBCacheMFAState' }
            @{ Name = 'LicenseOverview';        Fn = 'Set-CIPPDBCacheLicenseOverview' }
        )
    }
    Identity = @{
        Description = 'Users, guests, risky sign-ins, MFA registration'
        Types = @(
            @{ Name = 'RiskyUsers';                         Fn = 'Set-CIPPDBCacheRiskyUsers' }
            @{ Name = 'RiskDetections';                     Fn = 'Set-CIPPDBCacheRiskDetections' }
            @{ Name = 'CredentialUserRegistrationDetails';  Fn = 'Set-CIPPDBCacheCredentialUserRegistrationDetails' }
            @{ Name = 'UserRegistrationDetails';            Fn = 'Set-CIPPDBCacheUserRegistrationDetails' }
            @{ Name = 'RiskyServicePrincipals';             Fn = 'Set-CIPPDBCacheRiskyServicePrincipals' }
            @{ Name = 'ServicePrincipalRiskDetections';     Fn = 'Set-CIPPDBCacheServicePrincipalRiskDetections' }
            @{ Name = 'ServicePrincipals';                  Fn = 'Set-CIPPDBCacheServicePrincipals' }
            @{ Name = 'AppRoleAssignments';                 Fn = 'Set-CIPPDBCacheAppRoleAssignments' }
            @{ Name = 'OAuth2PermissionGrants';             Fn = 'Set-CIPPDBCacheOAuth2PermissionGrants' }
            @{ Name = 'Apps';                               Fn = 'Set-CIPPDBCacheApps' }
        )
    }
    Exchange = @{
        Description = 'Mailboxes, transport rules, anti-spam/phish/malware policies'
        Types = @(
            @{ Name = 'Mailboxes';                      Fn = 'Set-CIPPDBCacheMailboxes' }
            @{ Name = 'CASMailboxes';                   Fn = 'Set-CIPPDBCacheCASMailboxes' }
            @{ Name = 'MailboxUsage';                   Fn = 'Set-CIPPDBCacheMailboxUsage' }
            @{ Name = 'ExoTransportRules';              Fn = 'Set-CIPPDBCacheExoTransportRules' }
            @{ Name = 'ExoMalwareFilterPolicies';       Fn = 'Set-CIPPDBCacheExoMalwareFilterPolicies' }
            @{ Name = 'ExoAntiPhishPolicies';           Fn = 'Set-CIPPDBCacheExoAntiPhishPolicies' }
            @{ Name = 'ExoSafeAttachmentPolicies';      Fn = 'Set-CIPPDBCacheExoSafeAttachmentPolicies' }
            @{ Name = 'ExoSafeLinksPolicies';           Fn = 'Set-CIPPDBCacheExoSafeLinksPolicies' }
            @{ Name = 'ExoAtpPolicyForO365';            Fn = 'Set-CIPPDBCacheExoAtpPolicyForO365' }
            @{ Name = 'ExoHostedContentFilterPolicy';   Fn = 'Set-CIPPDBCacheExoHostedContentFilterPolicy' }
            @{ Name = 'ExoHostedOutboundSpamFilterPolicy'; Fn = 'Set-CIPPDBCacheExoHostedOutboundSpamFilterPolicy' }
            @{ Name = 'ExoSharingPolicy';               Fn = 'Set-CIPPDBCacheExoSharingPolicy' }
            @{ Name = 'ExoRemoteDomain';                Fn = 'Set-CIPPDBCacheExoRemoteDomain' }
            @{ Name = 'ExoAcceptedDomains';             Fn = 'Set-CIPPDBCacheExoAcceptedDomains' }
            @{ Name = 'ExoDkimSigningConfig';           Fn = 'Set-CIPPDBCacheExoDkimSigningConfig' }
            @{ Name = 'ExoAdminAuditLogConfig';         Fn = 'Set-CIPPDBCacheExoAdminAuditLogConfig' }
            @{ Name = 'ExoOrganizationConfig';          Fn = 'Set-CIPPDBCacheExoOrganizationConfig' }
            @{ Name = 'ExoPresetSecurityPolicy';        Fn = 'Set-CIPPDBCacheExoPresetSecurityPolicy' }
            @{ Name = 'ExoQuarantinePolicy';            Fn = 'Set-CIPPDBCacheExoQuarantinePolicy' }
            @{ Name = 'ExoTenantAllowBlockList';        Fn = 'Set-CIPPDBCacheExoTenantAllowBlockList' }
        )
    }
    SharePoint = @{
        Description = 'SharePoint and OneDrive usage'
        Types = @(
            @{ Name = 'SharePointSiteUsage';    Fn = 'Set-CIPPDBCacheSharePointSiteUsage' }
            @{ Name = 'OneDriveUsage';          Fn = 'Set-CIPPDBCacheOneDriveUsage' }
        )
    }
    Intune = @{
        Description = 'Managed devices, policies, encryption, detected apps'
        Types = @(
            @{ Name = 'ManagedDevices';                 Fn = 'Set-CIPPDBCacheManagedDevices' }
            @{ Name = 'ManagedDeviceEncryptionStates';   Fn = 'Set-CIPPDBCacheManagedDeviceEncryptionStates' }
            @{ Name = 'IntunePolicies';                 Fn = 'Set-CIPPDBCacheIntunePolicies' }
            @{ Name = 'IntuneAppProtectionPolicies';    Fn = 'Set-CIPPDBCacheIntuneAppProtectionPolicies' }
            @{ Name = 'DetectedApps';                   Fn = 'Set-CIPPDBCacheDetectedApps' }
            @{ Name = 'DeviceSettings';                 Fn = 'Set-CIPPDBCacheDeviceSettings' }
            @{ Name = 'DeviceRegistrationPolicy';       Fn = 'Set-CIPPDBCacheDeviceRegistrationPolicy' }
        )
    }
    Security = @{
        Description = 'Conditional Access, authorization, cross-tenant, B2B'
        Types = @(
            @{ Name = 'ConditionalAccessPolicies';      Fn = 'Set-CIPPDBCacheConditionalAccessPolicies' }
            @{ Name = 'AuthorizationPolicy';            Fn = 'Set-CIPPDBCacheAuthorizationPolicy' }
            @{ Name = 'CrossTenantAccessPolicy';        Fn = 'Set-CIPPDBCacheCrossTenantAccessPolicy' }
            @{ Name = 'B2BManagementPolicy';            Fn = 'Set-CIPPDBCacheB2BManagementPolicy' }
            @{ Name = 'AdminConsentRequestPolicy';      Fn = 'Set-CIPPDBCacheAdminConsentRequestPolicy' }
            @{ Name = 'DefaultAppManagementPolicy';     Fn = 'Set-CIPPDBCacheDefaultAppManagementPolicy' }
            @{ Name = 'AuthenticationFlowsPolicy';      Fn = 'Set-CIPPDBCacheAuthenticationFlowsPolicy' }
            @{ Name = 'AuthenticationMethodsPolicy';    Fn = 'Set-CIPPDBCacheAuthenticationMethodsPolicy' }
            @{ Name = 'SensitivityLabels';              Fn = 'Set-CIPPDBCacheSensitivityLabels' }
            @{ Name = 'DlpCompliancePolicies';          Fn = 'Set-CIPPDBCacheDlpCompliancePolicies' }
        )
    }
    Copilot = @{
        Description = 'Copilot readiness and usage analytics'
        Types = @(
            @{ Name = 'CopilotReadinessActivity';       Fn = 'Set-CIPPDBCacheCopilotReadinessActivity' }
            @{ Name = 'CopilotUsageUserDetail';         Fn = 'Set-CIPPDBCacheCopilotUsageUserDetail' }
            @{ Name = 'CopilotUserCountSummary';        Fn = 'Set-CIPPDBCacheCopilotUserCountSummary' }
            @{ Name = 'CopilotUserCountTrend';          Fn = 'Set-CIPPDBCacheCopilotUserCountTrend' }
        )
    }
    PIM = @{
        Description = 'Roles, PIM settings, role assignments, eligibility'
        Types = @(
            @{ Name = 'Roles';                          Fn = 'Set-CIPPDBCacheRoles' }
            @{ Name = 'PIMSettings';                    Fn = 'Set-CIPPDBCachePIMSettings' }
            @{ Name = 'RoleAssignmentScheduleInstances'; Fn = 'Set-CIPPDBCacheRoleAssignmentScheduleInstances' }
            @{ Name = 'RoleEligibilitySchedules';       Fn = 'Set-CIPPDBCacheRoleEligibilitySchedules' }
            @{ Name = 'RoleManagementPolicies';         Fn = 'Set-CIPPDBCacheRoleManagementPolicies' }
        )
    }
    Compliance = @{
        Description = 'BitLocker keys, MDE onboarding, directory recommendations'
        Types = @(
            @{ Name = 'BitlockerKeys';                  Fn = 'Set-CIPPDBCacheBitlockerKeys' }
            @{ Name = 'MDEOnboarding';                  Fn = 'Set-CIPPDBCacheMDEOnboarding' }
            @{ Name = 'DirectoryRecommendations';       Fn = 'Set-CIPPDBCacheDirectoryRecommendations' }
        )
    }
    Other = @{
        Description = 'Domains, settings, organization, office activations'
        Types = @(
            @{ Name = 'Domains';                        Fn = 'Set-CIPPDBCacheDomains' }
            @{ Name = 'Settings';                       Fn = 'Set-CIPPDBCacheSettings' }
            @{ Name = 'Organization';                   Fn = 'Set-CIPPDBCacheOrganization' }
            @{ Name = 'OfficeActivations';              Fn = 'Set-CIPPDBCacheOfficeActivations' }
        )
    }
}

# ─── Resolve categories ──────────────────────────────────────────────────────
if ($Categories) {
    $SyncCategories = [ordered]@{}
    foreach ($cat in $Categories) {
        $key = $cat.Substring(0,1).ToUpper() + $cat.Substring(1).ToLower()
        if ($AllCategories.Contains($key)) {
            $SyncCategories[$key] = $AllCategories[$key]
        } else {
            Write-Host "⚠ Unknown category: $cat (valid: $($AllCategories.Keys -join ', '))" -ForegroundColor Yellow
        }
    }
    if ($SyncCategories.Count -eq 0) {
        Write-Host "No valid categories. Exiting." -ForegroundColor Red
        exit 1
    }
} else {
    $SyncCategories = $AllCategories
}

# Count total types
$TotalTypes = 0
foreach ($cat in $SyncCategories.Values) { $TotalTypes += $cat.Types.Count }
Write-Host "Categories: $($SyncCategories.Keys -join ', ') ($TotalTypes cache types)" -ForegroundColor Cyan

# ─── Discover tenants ────────────────────────────────────────────────────────
if ($TenantFilter) {
    $Tenants = @([PSCustomObject]@{
        RowKey            = $TenantFilter
        defaultDomainName = $TenantFilter
        displayName       = $TenantFilter
        GraphErrorCount   = 0
    })
} else {
    Write-Host "`n=== Discovering tenants ===" -ForegroundColor Cyan
    $TenantsTable = Get-CIPPTable -TableName 'Tenants'
    $AllTenants = Get-CIPPAzDataTableEntity @TenantsTable
    $Tenants = @($AllTenants | Where-Object {
        $_.RowKey -ne 'Failed' -and
        $_.defaultDomainName -and
        [int]$_.GraphErrorCount -lt $MaxErrorCount
    })
    Write-Host "Found $($Tenants.Count) active tenant(s)" -ForegroundColor White
    foreach ($t in $Tenants) {
        Write-Host "  • $($t.displayName) ($($t.defaultDomainName)) — Errors: $($t.GraphErrorCount)" -ForegroundColor Gray
    }
}

if ($Tenants.Count -eq 0) {
    Write-Host "No tenants to sync. Exiting." -ForegroundColor Yellow
    exit 0
}

# ─── Dry run ─────────────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host "`n=== DRY RUN — would sync ===" -ForegroundColor Magenta
    foreach ($catName in $SyncCategories.Keys) {
        $cat = $SyncCategories[$catName]
        Write-Host "`n[$catName] $($cat.Description)" -ForegroundColor White
        foreach ($t in $cat.Types) {
            Write-Host "  • $($t.Name) → $($t.Fn)" -ForegroundColor Gray
        }
    }
    Write-Host "`nTenants: $($Tenants.Count) × Types: $TotalTypes = $($Tenants.Count * $TotalTypes) operations" -ForegroundColor Magenta
    exit 0
}

# ─── Sync ────────────────────────────────────────────────────────────────────
$GlobalStart = Get-Date
$GlobalSuccess = 0
$GlobalFailed = 0
$GlobalSkipped = 0
$TenantResults = @()

foreach ($Tenant in $Tenants) {
    $TenantDomain = $Tenant.defaultDomainName
    $TenantName = $Tenant.displayName
    $TenantStart = Get-Date

    Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Tenant: $TenantName ($TenantDomain)" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan

    $TenantSuccess = 0
    $TenantFailed = 0
    $TenantSkipped = 0

    foreach ($catName in $SyncCategories.Keys) {
        $cat = $SyncCategories[$catName]
        Write-Host "`n  [$catName] $($cat.Description)" -ForegroundColor DarkCyan

        foreach ($TypeInfo in $cat.Types) {
            $Type = $TypeInfo.Name
            $FunctionName = $TypeInfo.Fn
            $TypeStart = Get-Date

            # Check if function exists
            $Function = Get-Command -Name $FunctionName -ErrorAction SilentlyContinue
            if (-not $Function) {
                Write-Host "    [$Type] ⏭ skipped (function not found)" -ForegroundColor DarkGray
                $TenantSkipped++
                $GlobalSkipped++
                continue
            }

            Write-Host "    [$Type] " -ForegroundColor Yellow -NoNewline

            try {
                & $FunctionName -TenantFilter $TenantDomain

                $CountRow = Get-CIPPDbItem -TenantFilter $TenantDomain -Type $Type -Count
                $DataCount = if ($CountRow) { $CountRow.DataCount } else { '?' }
                $Elapsed = [math]::Round(((Get-Date) - $TypeStart).TotalSeconds, 1)

                Write-Host "✅ $DataCount records (${Elapsed}s)" -ForegroundColor Green
                $TenantSuccess++
            } catch {
                $Elapsed = [math]::Round(((Get-Date) - $TypeStart).TotalSeconds, 1)
                $errMsg = $_.Exception.Message
                if ($errMsg.Length -gt 60) { $errMsg = $errMsg.Substring(0, 60) + '...' }
                Write-Host "❌ ${Elapsed}s: $errMsg" -ForegroundColor Red
                $TenantFailed++
            }

            # Throttle: 0.5s between calls to avoid Graph throttling
            Start-Sleep -Milliseconds 500
        }
    }

    $TenantElapsed = [math]::Round(((Get-Date) - $TenantStart).TotalSeconds, 1)
    $TenantTotal = $TenantSuccess + $TenantFailed
    Write-Host "`n  ── Tenant done: $TenantSuccess/$TenantTotal OK, $TenantSkipped skipped, ${TenantElapsed}s" -ForegroundColor $(if ($TenantFailed -eq 0) { 'Green' } else { 'Yellow' })

    $GlobalSuccess += $TenantSuccess
    $GlobalFailed += $TenantFailed
    $TenantResults += [PSCustomObject]@{
        Tenant  = $TenantName
        Domain  = $TenantDomain
        Success = $TenantSuccess
        Failed  = $TenantFailed
        Skipped = $TenantSkipped
        Elapsed = "${TenantElapsed}s"
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$GlobalElapsed = [math]::Round(((Get-Date) - $GlobalStart).TotalSeconds, 1)
$GlobalTotal = $GlobalSuccess + $GlobalFailed

Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "DONE — $($Tenants.Count) tenant(s), $GlobalSuccess/$GlobalTotal types OK, $GlobalFailed failed, $GlobalSkipped skipped, ${GlobalElapsed}s total" -ForegroundColor $(if ($GlobalFailed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
$TenantResults | Format-Table -AutoSize | Out-String | Write-Host
