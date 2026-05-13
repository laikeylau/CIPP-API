$env:AzureWebJobsStorage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
$env:NonLocalHostAzurite = "true"
$env:CIPPRootPath = "/root/cipp-deploy/CIPP-API"
Import-Module ./Modules/CIPPCore -Force

$CIPPAppId = "98779b37-04c7-4714-887a-0c3bae41cb82"

$Table = Get-CIPPTable -TableName Tenants
$Tenants = Get-CIPPAzDataTableEntity @Table

Write-Host "=========================================="
Write-Host "CIPP-SAM Re-consent URLs for all tenants"
Write-Host "=========================================="
Write-Host ""

foreach ($T in $Tenants) {
    $TenantId = $T.customerId
    $Domain = $T.defaultDomainName
    if (-not $TenantId) { continue }
    
    $ConsentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$CIPPAppId&redirect_uri=https://mtm.cxty.de/authredirect"
    
    Write-Host "Tenant: $Domain ($TenantId)"
    Write-Host "Consent URL: $ConsentUrl"
    Write-Host ""
}

Write-Host "=========================================="
Write-Host "EXO Compliance RBAC Check"
Write-Host "=========================================="
Write-Host ""

foreach ($T in $Tenants) {
    $TenantId = $T.customerId
    $Domain = $T.defaultDomainName
    if (-not $TenantId) { continue }
    
    Write-Host "Tenant: $Domain"
    
    try {
        # Check if CIPP-SAM has Compliance Admin role in EXO
        $ExoResult = New-ExoRequest -TenantId $TenantId -cmdlet 'Get-ManagementRoleAssignment' -AsApp -cmdParams @{ 
            Role = 'Compliance Administrator'
            RoleAssignee = 'CIPP-SAM'
        } -ErrorAction SilentlyContinue
        
        if ($ExoResult) {
            Write-Host "  Compliance Admin: ASSIGNED"
        } else {
            Write-Host "  Compliance Admin: NOT ASSIGNED (needs fix)"
        }
    } catch {
        Write-Host "  Compliance check error: $($_.Exception.Message)"
    }
    Write-Host ""
}
