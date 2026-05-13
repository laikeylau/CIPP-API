$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module ./Modules/CIPPCore -Force

$CIPPAppId = "98779b37-04c7-4714-887a-0c3bae41cb82"

# Check the CIPP-SAM app registration in the home tenant (llatech)
$TenantId = "2b2ccf22-1af7-4ef4-a191-ad9b9a3b5de1"

Write-Host "=== CIPP-SAM App Registration ==="
try {
    $App = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$CIPPAppId'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
    if ($App) {
        Write-Host "App: $($App.displayName) (id: $($App.id))"
        Write-Host "Required Resource Accesses:"
        foreach ($RA in $App.requiredResourceAccess) {
            $ResourceSP = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($RA.resourceAppId)'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction SilentlyContinue
            $ResourceName = if ($ResourceSP) { $ResourceSP.displayName } else { $RA.resourceAppId }
            Write-Host "  Resource: $ResourceName ($($RA.resourceAppId))"
            foreach ($Perm in $RA.resourceAccess) {
                Write-Host "    $($Perm.id) type=$($Perm.type)"
            }
        }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}

# Check what Directory.Read.All role ID is on Microsoft Graph
Write-Host ""
Write-Host "=== Microsoft Graph App Roles (key ones) ==="
$GraphAppId = "00000003-0000-0000-c000-000000000000"
$GraphSP = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$GraphAppId'" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
if ($GraphSP) {
    Write-Host "Graph SP: $($GraphSP.id)"
    $GraphRoles = New-GraphGetRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($GraphSP.id)/appRoles" -TenantID $TenantId -AsApp $true -NoAuthCheck $true -ErrorAction Stop
    
    $KeyNames = @("Directory.Read.All", "Directory.ReadWrite.All", "User.Read.All", "User.ReadWrite.All", "AuditLog.Read.All", "MailboxSettings.ReadWrite", "Reports.Read.All")
    foreach ($Name in $KeyNames) {
        $Role = $GraphRoles | Where-Object { $_.value -eq $Name }
        if ($Role) {
            Write-Host "  $Name : $($Role.id)"
        }
    }
}
