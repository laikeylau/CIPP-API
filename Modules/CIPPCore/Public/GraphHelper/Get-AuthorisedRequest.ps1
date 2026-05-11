
function Get-AuthorisedRequest {
    <#
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    Param(
        [string]$TenantID,
        [string]$Uri
    )
    if (!$TenantID) {
        $TenantID = $env:TenantID
    }

    Write-Host "Get-AuthorisedRequest: TenantID='$TenantID' Uri='$Uri'"

    if ($Uri -like 'https://graph.microsoft.com/beta/contracts*' -or $Uri -like '*/customers/*' -or $Uri -eq 'https://graph.microsoft.com/v1.0/me/sendMail' -or $Uri -like '*/tenantRelationships/*' -or $Uri -like '*/security/partner/*') {
        Write-Host "Get-AuthorisedRequest: Allowed by URI whitelist"
        return $true
    }
    $Tenant = Get-Tenants -IncludeErrors -TenantFilter $TenantID | Where-Object { $_.Excluded -eq $false }

    Write-Host "Get-AuthorisedRequest: Tenant found = $($Tenant.Count) ($($Tenant.customerId) - $($Tenant.displayName))"

    if ($Tenant) {
        return $true
    } else {
        return $false
    }
}
