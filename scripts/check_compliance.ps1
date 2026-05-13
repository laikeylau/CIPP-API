$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module ./Modules/CIPPCore -Force

$TenantId = "2df8b2f9-1714-4246-825d-d655b1577ec3"
$CIPPSPId = "32b848ac-5aa5-428c-98b7-fc5c0a9f6d8c"

# Check assigned roles
Write-Host "=== CIPP-SAM Assigned Roles in Lenit Tech ==="
$Roles = New-GraphGetRequest -Uri "v1.0/servicePrincipals/$CIPPSPId/appRoleAssignments" -TenantID $TenantId -AsApp $true
$Roles | ForEach-Object {
    Write-Host "  $($_.appRoleId) - $($_.resourceDisplayName)"
}

# Check EXO Management App roles
Write-Host ""
Write-Host "=== Check EXO App Role Assignments ==="
$ExoAppId = "00000002-0000-0ff1-ce00-000000000000"
$ExoSP = New-GraphGetRequest -Uri "v1.0/servicePrincipals?`$filter=appId eq '$ExoAppId'" -TenantID $TenantId -AsApp $true
if ($ExoSP) {
    Write-Host "EXO SP: $($ExoSP.displayName) (id: $($ExoSP.id))"
    
    # Check app roles assigned TO CIPP-SAM from EXO
    $ExoAssignments = New-GraphGetRequest -Uri "v1.0/servicePrincipals/$CIPPSPId/appRoleAssignments?`$filter=resourceId eq guid'$($ExoSP.id)'" -TenantID $TenantId -AsApp $true -ErrorAction SilentlyContinue
    if ($ExoAssignments) {
        Write-Host "EXO roles assigned to CIPP-SAM:"
        $ExoAssignments | ForEach-Object { Write-Host "  $($_.appRoleId)" }
    } else {
        Write-Host "No EXO roles found via filter, listing all..."
        $AllRoles = New-GraphGetRequest -Uri "v1.0/servicePrincipals/$CIPPSPId/appRoleAssignments" -TenantID $TenantId -AsApp $true
        $AllRoles | Where-Object { $_.resourceId -eq $ExoSP.id } | ForEach-Object {
            Write-Host "  EXO Role: $($_.appRoleId)"
        }
    }
}

# Check Compliance roles on EXO SP
Write-Host ""
Write-Host "=== EXO App Roles (Compliance related) ==="
if ($ExoSP) {
    $AppRoles = New-GraphGetRequest -Uri "v1.0/servicePrincipals/$($ExoSP.id)/appRoles" -TenantID $TenantId -AsApp $true
    $AppRoles | Where-Object { $_.displayName -match "Compliance" -or $_.value -match "Compliance" } | ForEach-Object {
        Write-Host "  $($_.value) - $($_.displayName) (id: $($_.id))"
    }
}

# Also check for Compliance Center SP
Write-Host ""
Write-Host "=== Security & Compliance SP ==="
$ComplianceAppId = "00000007-0000-0ff1-ce00-000000000000"
$ComplianceSP = New-GraphGetRequest -Uri "v1.0/servicePrincipals?`$filter=appId eq '$ComplianceAppId'" -TenantID $TenantId -AsApp $true -ErrorAction SilentlyContinue
if ($ComplianceSP) {
    Write-Host "Compliance SP found: $($ComplianceSP.displayName) (id: $($ComplianceSP.id))"
} else {
    Write-Host "No Security & Compliance SP found"
}
