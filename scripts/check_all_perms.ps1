$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module ./Modules/CIPPCore -Force

$CIPPAppId = "98779b37-04c7-4714-887a-0c3bae41cb82"

# Get all tenants
$Table = Get-CIPPTable -TableName Tenants
$Tenants = Get-CIPPAzDataTableEntity @Table

foreach ($T in $Tenants) {
    $TenantId = $T.customerId
    $Domain = $T.defaultDomainName
    if (-not $TenantId) { continue }
    
    Write-Host "========================================"
    Write-Host "Tenant: $Domain ($TenantId)"
    Write-Host "========================================"
    
    try {
        # Check CIPP-SAM SP in this tenant
        $SP = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$CIPPAppId'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
        if ($SP) {
            Write-Host "  CIPP-SAM SP: $($SP.id)"
            
            # Check assigned roles
            $Roles = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($SP.id)/appRoleAssignments" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
            Write-Host "  Assigned App Roles: $($Roles.Count)"
            
            # Check for specific permissions
            foreach ($R in $Roles) {
                $Resource = $null
                try {
                    $Resource = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($R.resourceId)" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction SilentlyContinue
                } catch {}
                $ResourceName = if ($Resource) { $Resource.displayName } else { $R.resourceId }
                Write-Host "    Role: $($R.appRoleId) -> $ResourceName"
            }
            
            # Check for required roles
            $RequiredRoles = @{
                "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a37" = "Application.Read.All"
                "bf394be3-5869-4435-9473-b8b2a3e30038" = "Directory.Read.All"
                "230c1aed-a721-4c5d-9cb4-a90514e508ef" = "Reports.Read.All"
                "741f803b-c850-43c7-bf62-6faa30a4df82" = "User.Read.All"
                "df021288-bdef-4463-88db-98f22de89214" = "User.ReadWrite.All"
                "2f670e14-5be2-4faa-9300-21b2d6e1e332" = "AuditLog.Read.All"
                "e330c4f0-4175-449e-8d70-595245e383a1" = "MailboxSettings.ReadWrite"
                "62a82d76-70ea-41e2-9197-3f99041f93b1" = "Contacts.ReadWrite"
                "4908d5b9-3fb2-4b66-b09b-6987523e3999" = "Calendars.ReadWrite"
            }
            
            Write-Host ""
            Write-Host "  Required Role Check:"
            foreach ($RoleId in $RequiredRoles.Keys) {
                $Assigned = $Roles | Where-Object { $_.appRoleId -eq $RoleId }
                $Status = if ($Assigned) { "OK" } else { "MISSING" }
                Write-Host "    $Status : $($RequiredRoles[$RoleId]) ($RoleId)"
            }
            
            # Check EXO roles
            Write-Host ""
            Write-Host "  EXO Roles:"
            $ExoRoles = $Roles | Where-Object { $_.resourceDisplayName -match "Office 365 Exchange Online" }
            if ($ExoRoles) {
                Write-Host "    Exchange roles found: $($ExoRoles.Count)"
                foreach ($ER in $ExoRoles) {
                    Write-Host "      $($ER.appRoleId)"
                }
            } else {
                Write-Host "    NO Exchange roles assigned!"
            }
            
        } else {
            Write-Host "  CIPP-SAM SP NOT FOUND in this tenant!"
        }
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}
