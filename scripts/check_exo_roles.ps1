$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module ./Modules/CIPPCore -Force

$CIPPAppId = "98779b37-04c7-4714-887a-0c3bae41cb82"
$ExoAppId = "00000002-0000-0ff1-ce00-000000000000"

$Table = Get-CIPPTable -TableName Tenants
$Tenants = Get-CIPPAzDataTableEntity @Table

foreach ($T in $Tenants) {
    $TenantId = $T.customerId
    $Domain = $T.defaultDomainName
    if (-not $TenantId) { continue }
    
    Write-Host "=== $Domain ==="
    
    try {
        # Check EXO service principal
        $ExoSP = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ExoAppId'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
        if ($ExoSP) {
            Write-Host "  EXO SP: $($ExoSP.id)"
            
            # Check app roles on EXO SP
            $ExoAppRoles = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ExoSP.id)/appRoles" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
            Write-Host "  EXO App Roles available: $($ExoAppRoles.Count)"
            
            # Check which EXO roles are assigned to CIPP-SAM
            $SP = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$CIPPAppId'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
            $Roles = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($SP.id)/appRoleAssignments" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
            
            $ExoAssigned = $Roles | Where-Object { $_.resourceId -eq $ExoSP.id }
            Write-Host "  EXO roles assigned to CIPP-SAM: $($ExoAssigned.Count)"
            foreach ($R in $ExoAssigned) {
                $MatchedRole = $ExoAppRoles | Where-Object { $_.id -eq $R.appRoleId }
                $RoleName = if ($MatchedRole) { $MatchedRole.value } else { $R.appRoleId }
                Write-Host "    - $RoleName"
            }
            
            # Check for Compliance-related roles
            $ComplianceRoles = $ExoAppRoles | Where-Object { $_.value -match "Compliance" -or $_.displayName -match "Compliance" }
            Write-Host "  Available Compliance roles: $($ComplianceRoles.Count)"
            foreach ($CR in $ComplianceRoles) {
                $Assigned = $ExoAssigned | Where-Object { $_.appRoleId -eq $CR.id }
                $Status = if ($Assigned) { "OK" } else { "MISSING" }
                Write-Host "    $Status : $($CR.value) ($($CR.id))"
            }
        }
        
        # Check OAuth2 permission grants (for delegated consent)
        Write-Host ""
        Write-Host "  OAuth2 Permission Grants:"
        $Grants = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($SP.id)'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
        foreach ($G in $Grants) {
            Write-Host "    Resource: $($G.resourceId) Scope: $($G.scope)"
        }
        
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}
