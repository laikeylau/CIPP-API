#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Setup ALL CIPP-SAM permissions for a tenant (Graph + EXO + Directory Roles)
    Ensures no permission is missing for any new tenant.

.DESCRIPTION
    Grants all required app role assignments from:
    - Microsoft Graph (59 permissions)
    - Office 365 Exchange Online (2 permissions)  
    - Exchange Administrator directory role
    
    Idempotent: skips already-granted permissions.

.PARAMETER TenantId
    Target tenant ID

.PARAMETER DryRun
    Preview what would be granted without making changes

.EXAMPLE
    ./Setup-TenantPermissions.ps1 -TenantId "2df8b2f9-1714-4246-825d-d655b1577ec3"
    ./Setup-TenantPermissions.ps1 -TenantId "xxx" -DryRun
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Environment Setup ---
$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module "/root/cipp-deploy/CIPP-API/Modules/CIPPCore" -Force
Import-Module "/root/cipp-deploy/CIPP-API/Modules/AzBobbyTables" -Force

$Auth = Get-CIPPAuthentication
$AppId = $env:ApplicationID

# --- Required Permissions ---
$GraphPermissions = @(
    "AccessReview.ReadWrite.All",
    "AppCatalog.ReadWrite.All",
    "Application.Read.All",
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All",
    "AuditLog.Read.All",
    "AuditLogsQuery.Read.All",
    "Calendars.ReadWrite",
    "Channel.Delete.All",
    "ConsentRequest.ReadWrite.All",
    "Contacts.ReadWrite",
    "CrossTenantInformation.ReadBasic.All",
    "DelegatedAdminRelationship.Read.All",
    "DelegatedAdminRelationship.ReadWrite.All",
    "DeviceManagementApps.Read.All",
    "DeviceManagementApps.ReadWrite.All",
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementConfiguration.ReadWrite.All",
    "DeviceManagementManagedDevices.PrivilegedOperations.All",
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "DeviceManagementRBAC.Read.All",
    "DeviceManagementRBAC.ReadWrite.All",
    "DeviceManagementScripts.Read.All",
    "DeviceManagementScripts.ReadWrite.All",
    "Directory.Read.All",
    "Directory.ReadWrite.All",
    "Domain.Read.All",
    "Domain.ReadWrite.All",
    "Group.Read.All",
    "Group.ReadWrite.All",
    "IdentityRiskEvent.Read.All",
    "IdentityRiskyUser.Read.All",
    "Mail.ReadWrite",
    "Mail.Send",
    "MailboxSettings.ReadWrite",
    "NetworkAccess.Read.All",
    "Organization.ReadWrite.All",
    "Policy.Read.All",
    "Policy.ReadWrite.ConditionalAccess",
    "Reports.Read.All",
    "RoleManagement.ReadWrite.Directory",
    "SecurityActions.Read.All",
    "SecurityActions.ReadWrite.All",
    "SecurityAlert.Read.All",
    "SecurityAlert.ReadWrite.All",
    "SecurityEvents.Read.All",
    "SecurityEvents.ReadWrite.All",
    "Sites.FullControl.All",
    "Sites.Read.All",
    "Sites.ReadWrite.All",
    "Team.ReadBasic.All",
    "TeamMember.ReadWrite.All",
    "TeamSettings.ReadWrite.All",
    "ThreatAssessment.Read.All",
    "User.Read.All",
    "User.ReadWrite.All",
    "UserAuthenticationMethod.Read.All",
    "UserAuthenticationMethod.ReadWrite.All"
)

$ExoPermissions = @(
    "Exchange.ManageAsApp",
    "Exchange.ManageAsAppV2"
)

$DirectoryRoles = @(
    @{ Name = "Exchange Administrator"; Id = "29232cdf-9323-42fd-ade2-1d097af3e4de" }
)

# --- Helper: Lookup SP by appId ---
function Get-SPByAppId {
    param([string]$AppIdValue, [hashtable]$Headers)
    $Result = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppIdValue'" -Method GET -Headers $Headers
    return $Result.value[0]
}

# --- Helper: Grant App Role ---
function Grant-AppRole {
    param(
        [string]$SPId,
        [string]$ResourceId,
        [string]$RoleId,
        [string]$RoleName,
        [string]$ResourceName,
        [hashtable]$Headers
    )
    
    $Label = "$ResourceName | $RoleName"
    
    # Check existing assignments (cached per run)
    if (-not $script:ExistingAssignments) {
        $script:ExistingAssignments = @{}
        $Page = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SPId/appRoleAssignments?`$top=200" -Method GET -Headers $Headers
        foreach ($A in $Page.value) {
            $Key = "$($A.resourceId)|$($A.appRoleId)"
            $script:ExistingAssignments[$Key] = $true
        }
    }
    
    $CheckKey = "$ResourceId|$RoleId"
    if ($script:ExistingAssignments.ContainsKey($CheckKey)) {
        Write-Host "  [OK] $Label" -ForegroundColor Green
        return "skip"
    }
    
    if ($DryRun) {
        Write-Host "  [DRY] $Label" -ForegroundColor Yellow
        return "dry"
    }
    
    Write-Host "  [ADD] $Label" -ForegroundColor Yellow
    $Body = @{ principalId = $SPId; resourceId = $ResourceId; appRoleId = $RoleId } | ConvertTo-Json -Compress
    try {
        $Grant = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SPId/appRoleAssignments" -Method POST -Headers $Headers -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -ContentType "application/json" -ErrorAction Stop
        Write-Host "       -> Granted ($($Grant.id))" -ForegroundColor Green
        return "added"
    } catch {
        $em = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "       -> FAILED: $em" -ForegroundColor Red
        return "failed"
    }
}

# --- Main ---
Write-Host ""
Write-Host "=== CIPP-SAM Permission Setup for Tenant: $TenantId ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  [DRY RUN MODE]" -ForegroundColor Yellow }

$Token = Get-GraphToken -Tenantid $TenantId -scope "https://graph.microsoft.com/.default"

# Get CIPP-SAM SP in tenant
$SP = Get-SPByAppId -AppIdValue $AppId -Headers $Token
if (-not $SP) {
    Write-Host "[FAIL] CIPP-SAM SP not found in tenant. Run Admin Consent first:" -ForegroundColor Red
    Write-Host "  https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId" -ForegroundColor Green
    exit 1
}
Write-Host "CIPP-SAM SP: $($SP.id)" -ForegroundColor Gray

# Get resource SPs by appId
$GraphResAppId = "00000003-0000-0000-c000-000000000000"
$ExoResAppId   = "00000002-0000-0ff1-ce00-000000000000"

$GraphSP = Get-SPByAppId -AppIdValue $GraphResAppId -Headers $Token
$ExoSP   = Get-SPByAppId -AppIdValue $ExoResAppId -Headers $Token

if (-not $GraphSP) { Write-Host "[FAIL] Microsoft Graph SP not found" -ForegroundColor Red; exit 1 }
if (-not $ExoSP)   { Write-Host "[WARN] Exchange Online SP not found (EXO may not be provisioned)" -ForegroundColor Yellow }

Write-Host "Graph SP: $($GraphSP.id)" -ForegroundColor Gray
if ($ExoSP) { Write-Host "EXO SP:   $($ExoSP.id)" -ForegroundColor Gray }

# Cache existing assignments
$script:ExistingAssignments = $null

# --- Grant Microsoft Graph Permissions ---
Write-Host "`n--- Microsoft Graph ($($GraphPermissions.Count) permissions) ---" -ForegroundColor Cyan
$Added = 0; $Skipped = 0; $Failed = 0
foreach ($Perm in $GraphPermissions) {
    $Role = $GraphSP.appRoles | Where-Object { $_.value -eq $Perm }
    if (-not $Role) {
        Write-Host "  [WARN] $Perm not found on Graph SP" -ForegroundColor DarkYellow
        $Failed++
        continue
    }
    $Result = Grant-AppRole -SPId $SP.id -ResourceId $GraphSP.id -RoleId $Role.id -RoleName $Perm -ResourceName "Microsoft Graph" -Headers $Token
    switch ($Result) {
        "added"  { $Added++ }
        "skip"   { $Skipped++ }
        "failed" { $Failed++ }
    }
}

# --- Grant EXO Permissions ---
if ($ExoSP) {
    Write-Host "`n--- Office 365 Exchange Online ($($ExoPermissions.Count) permissions) ---" -ForegroundColor Cyan
    foreach ($Perm in $ExoPermissions) {
        $Role = $ExoSP.appRoles | Where-Object { $_.value -eq $Perm }
        if (-not $Role) {
            Write-Host "  [WARN] $Perm not found on EXO SP" -ForegroundColor DarkYellow
            $Failed++
            continue
        }
        $Result = Grant-AppRole -SPId $SP.id -ResourceId $ExoSP.id -RoleId $Role.id -RoleName $Perm -ResourceName "Exchange Online" -Headers $Token
        switch ($Result) {
            "added"  { $Added++ }
            "skip"   { $Skipped++ }
            "failed" { $Failed++ }
        }
    }
}

# --- Assign Directory Roles ---
Write-Host "`n--- Directory Roles ($($DirectoryRoles.Count) roles) ---" -ForegroundColor Cyan
foreach ($DirRole in $DirectoryRoles) {
    $ExistingRoles = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($SP.id)'" -Method GET -Headers $Token
    $Has = $ExistingRoles.value | Where-Object { $_.roleDefinitionId -eq $DirRole.Id }
    
    if ($Has) {
        Write-Host "  [OK] $($DirRole.Name)" -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host "  [DRY] $($DirRole.Name)" -ForegroundColor Yellow
    } else {
        Write-Host "  [ADD] $($DirRole.Name)" -ForegroundColor Yellow
        $Body = @{ principalId = $SP.id; roleDefinitionId = $DirRole.Id; directoryScope = "/" } | ConvertTo-Json -Compress
        try {
            $R = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" -Method POST -Headers $Token -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -ContentType "application/json" -ErrorAction Stop
            Write-Host "       -> Assigned ($($R.id))" -ForegroundColor Green
        } catch {
            $em = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            Write-Host "       -> API failed: $em" -ForegroundColor Red
            Write-Host "       -> Assign manually: Azure Portal > Entra ID > Roles > $($DirRole.Name) > Add assignments" -ForegroundColor Yellow
        }
    }
}

# --- Summary ---
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Graph:   $($GraphPermissions.Count) permissions" -ForegroundColor Gray
Write-Host "  EXO:     $($ExoPermissions.Count) permissions" -ForegroundColor Gray
Write-Host "  Roles:   $($DirectoryRoles.Count) directory roles" -ForegroundColor Gray
Write-Host "  Added:   $Added" -ForegroundColor Green
Write-Host "  Skipped: $Skipped" -ForegroundColor Gray
Write-Host "  Failed:  $Failed" -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "Green" })

if ($Added -gt 0) {
    Write-Host "`n[NOTE] New permissions granted. Run Admin Consent to activate:" -ForegroundColor Yellow
    Write-Host "  https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId&redirect_uri=https://mtm.cxty.de/authredirect" -ForegroundColor Green
}

Write-Host ""
