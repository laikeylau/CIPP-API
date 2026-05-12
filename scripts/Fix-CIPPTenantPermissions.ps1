#!/usr/bin/env pwsh
# Fix-CIPPTenantPermissions.ps1
# Grants additional permissions for a CIPP direct tenant
# Usage: pwsh -File Fix-CIPPTenantPermissions.ps1 -TenantId <tenant-id>

param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId
)

$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module /root/cipp-deploy/CIPP-API/Modules/CIPPCore -Force
Import-Module /root/cipp-deploy/CIPP-API/Modules/AzBobbyTables -Force

$Auth = Get-CIPPAuthentication
$AppId = $env:ApplicationID
$GraphResId = "00000003-0000-0000-c000-000000000000"

# Get delegated token for the target tenant
$Token = Get-GraphToken -Tenantid $TenantId -scope "https://graph.microsoft.com/.default"

Write-Host "=== Granting IdentityRiskyUser.Read.All for tenant $TenantId ===" -ForegroundColor Cyan

# Find CIPP-SAM service principal in tenant
$SPs = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'" -Method GET -Headers $Token
$SP = $SPs.value[0]
if (-not $SP) {
    Write-Host "  CIPP-SAM service principal not found in tenant!" -ForegroundColor Red
    exit 1
}
Write-Host "  CIPP-SAM SP: $($SP.id)"

# Find Microsoft Graph SP
$GraphSPs = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$GraphResId'" -Method GET -Headers $Token
$GraphSP = $GraphSPs.value[0]
Write-Host "  Graph SP: $($GraphSP.id)"

# Find IdentityRiskyUser.Read.All role
$RiskRole = $GraphSP.appRoles | Where-Object { $_.value -eq "IdentityRiskyUser.Read.All" }
if (-not $RiskRole) {
    Write-Host "  IdentityRiskyUser.Read.All role not found! SP may need refresh." -ForegroundColor Red
    exit 1
}
Write-Host "  Role: $($RiskRole.displayName) ($($RiskRole.id))"

# Check existing assignments
$Existing = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($SP.id)/appRoleAssignments" -Method GET -Headers $Token
$HasRisk = $Existing.value | Where-Object { $_.appRoleId -eq $RiskRole.id }
if ($HasRisk) {
    Write-Host "  [OK] Already granted" -ForegroundColor Green
} else {
    Write-Host "  Granting..." -ForegroundColor Yellow
    $GrantBody = @{principalId=$SP.id; resourceId=$GraphSP.id; appRoleId=$RiskRole.id} | ConvertTo-Json -Compress
    try {
        $Grant = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($SP.id)/appRoleAssignments" -Method POST -Headers $Token -Body ([System.Text.Encoding]::UTF8.GetBytes($GrantBody)) -ContentType "application/json" -ErrorAction Stop
        Write-Host "  [OK] Granted: $($Grant.id)" -ForegroundColor Green
    } catch {
        $em = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "  [INFO] Cannot grant programmatically: $em" -ForegroundColor Yellow
        Write-Host "  Admin consent needed. Visit:" -ForegroundColor Yellow
        Write-Host "  https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId&redirect_uri=https://mtm.cxty.de/authredirect" -ForegroundColor Green
    }
}

# Try Exchange Administrator role assignment
Write-Host "`n=== Exchange Administrator Role ===" -ForegroundColor Cyan
$ExchAdminRoleId = "29232cdf-9323-42fd-ade2-1d097af3e4de"

$ExistingRoles = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($SP.id)'" -Method GET -Headers $Token
$HasExch = $ExistingRoles.value | Where-Object { $_.roleDefinitionId -eq $ExchAdminRoleId }
if ($HasExch) {
    Write-Host "  [OK] Already assigned" -ForegroundColor Green
} else {
    Write-Host "  Assigning..." -ForegroundColor Yellow
    $Body = @{principalId=$SP.id; roleDefinitionId=$ExchAdminRoleId; directoryScope="/"} | ConvertTo-Json -Compress
    try {
        $R = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" -Method POST -Headers $Token -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -ContentType "application/json" -ErrorAction Stop
        Write-Host "  [OK] Assigned: $($R.id)" -ForegroundColor Green
    } catch {
        Write-Host "  [INFO] Cannot assign via API. Manual action needed:" -ForegroundColor Yellow
        Write-Host "  Azure Portal > Entra ID > Roles and administrators > Exchange Administrator" -ForegroundColor Yellow
        Write-Host "  > Add assignments > Select CIPP-SAM" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
