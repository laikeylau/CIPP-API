#!/usr/bin/env pwsh
<#
.SYNOPSIS
    CIPP Mode C: Setup Independent App Registration per Tenant
    为每个租户创建独立的 App Registration 并配置权限

.DESCRIPTION
    在目标租户中创建独立的 App Registration，配置所需的 Application Permissions，
    并将凭据存储到 Azurite DevSecrets 表中。适用于需要高安全隔离的场景。

.PARAMETER TenantId
    目标租户 ID (GUID)

.PARAMETER AppDisplayName
    App Registration 显示名称 (默认: CIPP-Managed)

.PARAMETER AdminCredential
    目标租户 Global Admin 凭据 (用于授权 Admin Consent)

.EXAMPLE
    ./Setup-TenantAppRegistration.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$AppDisplayName = "CIPP-Managed",

    [PSCredential]$AdminCredential,

    [string]$AzuriteConnectionString = "AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== CIPP Mode C: Independent App Registration Setup ===" -ForegroundColor Cyan
Write-Host "Target Tenant: $TenantId" -ForegroundColor DarkGray

# ── Step 1: Connect to Target Tenant ──
Write-Host "`n[1/6] Connecting to target tenant..." -ForegroundColor Yellow
try {
    if ($AdminCredential) {
        Connect-MgGraph -TenantId $TenantId -Credential $AdminCredential -NoWelcome
    } else {
        Connect-MgGraph -TenantId $TenantId -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome
    }
    $Context = Get-MgContext
    Write-Host "  ✅ Connected as $($Context.Account) to $($Context.TenantId)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Failed to connect: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Step 2: Create App Registration ──
Write-Host "`n[2/6] Creating App Registration '$AppDisplayName'..." -ForegroundColor Yellow
try {
    $ExistingApp = Get-MgApplication -Filter "displayName eq '$AppDisplayName'" -ErrorAction SilentlyContinue
    if ($ExistingApp) {
        Write-Host "  ⚠️ App '$AppDisplayName' already exists. Using existing." -ForegroundColor Yellow
        $App = $ExistingApp
    } else {
        $App = New-MgApplication -DisplayName $AppDisplayName -SignInAudience "AzureADMyOrg"
        Write-Host "  ✅ App created: AppId=$($App.AppId)" -ForegroundColor Green
    }
} catch {
    Write-Host "  ❌ Failed to create app: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Step 3: Create Client Secret ──
Write-Host "`n[3/6] Creating Client Secret..." -ForegroundColor Yellow
try {
    $Secret = Add-MgApplicationPassword -ApplicationId $App.Id -PasswordCredential @{
        DisplayName = "CIPP-Secret-$(Get-Date -Format 'yyyyMMdd')"
        EndDateTime = (Get-Date).AddYears(2)
    }
    Write-Host "  ✅ Secret created (expires: $($Secret.EndDateTime))" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Failed to create secret: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Step 4: Create Service Principal ──
Write-Host "`n[4/6] Creating Service Principal..." -ForegroundColor Yellow
try {
    $SP = Get-MgServicePrincipal -Filter "appId eq '$($App.AppId)'" -ErrorAction SilentlyContinue
    if (-not $SP) {
        $SP = New-MgServicePrincipal -AppId $App.AppId
        Write-Host "  ✅ Service Principal created" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ Service Principal already exists" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ❌ Failed to create SP: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Step 5: Assign Application Permissions ──
Write-Host "`n[5/6] Assigning Application Permissions..." -ForegroundColor Yellow

$GraphSP = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$RequiredPermissions = @(
    "Application.ReadWrite.All"
    "Directory.ReadWrite.All"
    "User.ReadWrite.All"
    "Group.ReadWrite.All"
    "Mail.ReadWrite"
    "Calendars.ReadWrite"
    "Sites.FullControl.All"
    "DeviceManagementManagedDevices.ReadWrite.All"
    "DeviceManagementConfiguration.ReadWrite.All"
    "Policy.ReadWrite.ConditionalAccess"
    "RoleManagement.ReadWrite.Directory"
    "AuditLog.Read.All"
    "SecurityEvents.ReadWrite.All"
    "Organization.ReadWrite.All"
    "Domain.ReadWrite.All"
    "Reports.Read.All"
    "Contacts.ReadWrite"
    "MailboxSettings.ReadWrite"
    "TeamSettings.ReadWrite.All"
    "ChannelSettings.ReadWrite.All"
    "Exchange.ManageAsApp"
)

$Assigned = 0
$Skipped = 0
foreach ($Permission in $RequiredPermissions) {
    $AppRole = $GraphSP.AppRoles | Where-Object { $_.Value -eq $Permission }
    if (-not $AppRole) {
        Write-Host "  ⚠️ Permission not found: $Permission" -ForegroundColor DarkYellow
        $Skipped++
        continue
    }

    # Check if already assigned
    $Existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SP.Id | Where-Object { $_.AppRoleId -eq $AppRole.Id }
    if ($Existing) {
        $Skipped++
        continue
    }

    try {
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SP.Id -PrincipalId $SP.Id -ResourceId $GraphSP.Id -AppRoleId $AppRole.Id | Out-Null
        Write-Host "  ✅ $Permission" -ForegroundColor Green
        $Assigned++
    } catch {
        Write-Host "  ❌ $Permission - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "  Assigned: $Assigned, Skipped (already exists or not found): $Skipped" -ForegroundColor DarkGray

# ── Step 6: Store Credentials in Azurite ──
Write-Host "`n[6/6] Storing credentials in Azurite..." -ForegroundColor Yellow
try {
    $Ctx = New-AzStorageContext -ConnectionString $AzuriteConnectionString
    $SecretsTable = Get-AzStorageTable -Name "DevSecrets" -Context $Ctx -ErrorAction SilentlyContinue
    if (-not $SecretsTable) {
        $SecretsTable = New-AzStorageTable -Name "DevSecrets" -Context $Ctx
    }
    $CloudTable = $SecretsTable.CloudTable

    $SafeTenantId = $TenantId -replace '-', '_'

    # Get existing secrets or create new
    $Existing = Get-CIPPAzDataTableEntity $CloudTable -Filter "PartitionKey eq 'Secret' and RowKey eq 'Secret'" -ErrorAction SilentlyContinue
    if ($Existing) {
        $Existing | Add-Member -MemberType NoteProperty -Name "AppId_$SafeTenantId" -Value $App.AppId -Force
        $Existing | Add-Member -MemberType NoteProperty -Name "AppSecret_$SafeTenantId" -Value $Secret.SecretText -Force
        Add-CIPPAzDataTableEntity $CloudTable -Entity $Existing -Force | Out-Null
    } else {
        $NewEntity = @{
            PartitionKey         = "Secret"
            RowKey               = "Secret"
            "AppId_$SafeTenantId"    = $App.AppId
            "AppSecret_$SafeTenantId" = $Secret.SecretText
        }
        Add-CIPPAzDataTableEntity $CloudTable -Entity $NewEntity -Force | Out-Null
    }

    Write-Host "  ✅ Credentials stored (AppId_$SafeTenantId)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Failed to store credentials: $($_.Exception.Message)" -ForegroundColor Red
}

# ── Summary ──
Write-Host "`n=== Setup Complete ===" -ForegroundColor Cyan
Write-Host @"

Tenant ID:        $TenantId
App Name:         $AppDisplayName
App ID:           $($App.AppId)
Secret Expires:   $($Secret.EndDateTime)
Service Principal: $($SP.Id)

Next Steps:
1. ⚠️ Grant Admin Consent in Azure Portal:
   Azure Portal → App Registrations → $AppDisplayName → API Permissions → Grant admin consent

2. Add tenant to CIPP (if not already done):
   Run ./Add-DirectTenant.ps1 -SingleTenant

3. Configure CIPP to use this app's credentials:
   Update Get-GraphToken.ps1 to read per-tenant AppId/AppSecret from DevSecrets

4. Test connectivity:
   Run ./Monitor-TenantHealth.ps1

"@ -ForegroundColor White

# Disconnect
Disconnect-MgGraph | Out-Null
