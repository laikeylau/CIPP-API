#!/usr/bin/env pwsh
<#
.SYNOPSIS
    CIPP Direct Tenant Management - Azurite Operations
    管理 Azurite 表存储中的租户记录

.PARAMETER Action
    list: 列出所有租户
    add: 添加新租户
    reset: 重置 GraphErrorCount
    delete: 删除租户
    import: 从 JSON 批量导入

.EXAMPLE
    ./Add-DirectTenant.ps1 -Action list
    ./Add-DirectTenant.ps1 -Action import -ConfigFile ./tenants-sample.json
    ./Add-DirectTenant.ps1 -Action reset -TenantId "xxx"
#>
[CmdletBinding()]
param(
    [ValidateSet('list','add','reset','delete','import')]
    [string]$Action = 'list',
    [string]$TenantId,
    [string]$DisplayName,
    [string]$DefaultDomain,
    [string]$InitialDomain,
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
$ConnStr = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"

Import-Module "$PSScriptRoot/../Modules/AzBobbyTables" -Force

function Get-TenantTable {
    $Ctx = New-AzDataTableContext -ConnectionString $ConnStr -TableName "Tenants"
    @{ Context = $Ctx }
}

Write-Host ""
Write-Host "=== CIPP Direct Tenant Manager ===" -ForegroundColor Cyan

switch ($Action) {
    'list' {
        $T = Get-TenantTable
        $Entities = Get-AzDataTableEntity @T
        $Tenants = $Entities | Where-Object { $_.PartitionKey -eq 'Tenants' }
        Write-Host ""
        Write-Host "Found $($Tenants.Count) tenant(s):" -ForegroundColor Yellow
        Write-Host ""
        foreach ($E in $Tenants) {
            $Name = if ($E.displayName) { $E.displayName } else { "(unknown)" }
            $Domain = if ($E.defaultDomainName) { $E.defaultDomainName } else { "(none)" }
            $Errors = if ($null -ne $E.GraphErrorCount) { $E.GraphErrorCount } else { 0 }
            $Status = if ($E.delegatedPrivilegeStatus) { $E.delegatedPrivilegeStatus } else { "(not set)" }
            $Color = if ($Errors -ge 50) { "Red" } elseif ($Errors -ge 10) { "Yellow" } else { "Green" }
            Write-Host "  Name: $Name" -ForegroundColor White
            Write-Host "  Domain: $Domain" -ForegroundColor Gray
            Write-Host "  TenantID: $($E.RowKey)" -ForegroundColor DarkGray
            Write-Host "  Errors: $Errors" -ForegroundColor $Color
            Write-Host "  Status: $Status" -ForegroundColor Gray
            Write-Host ""
        }
    }

    'add' {
        if (-not $TenantId) { Write-Host "[FAIL] -TenantId required" -ForegroundColor Red; exit 1 }
        if (-not $DisplayName) { $DisplayName = "Tenant $TenantId" }
        if (-not $DefaultDomain) { $DefaultDomain = "$TenantId.onmicrosoft.com" }

        $T = Get-TenantTable
        $Existing = Get-AzDataTableEntity @T -Filter "RowKey eq '$TenantId'"
        if ($Existing) {
            Write-Host "[SKIP] Tenant already exists: $($Existing.displayName)" -ForegroundColor Yellow
            exit 0
        }

        $Entity = @{
            PartitionKey             = 'Tenants'
            RowKey                   = $TenantId
            displayName              = $DisplayName
            defaultDomainName        = $DefaultDomain
            initialDomainName        = if ($InitialDomain) { $InitialDomain } else { $DefaultDomain }
            customerId               = $TenantId
            delegatedPrivilegeStatus = 'directTenant'
            GraphErrorCount          = 0
        }
        Add-AzDataTableEntity @T -Entity $Entity -Force
        Write-Host "[OK] Added: $DisplayName ($TenantId)" -ForegroundColor Green
    }

    'reset' {
        if (-not $TenantId) { Write-Host "[FAIL] -TenantId required" -ForegroundColor Red; exit 1 }
        $T = Get-TenantTable
        $Entity = Get-AzDataTableEntity @T -Filter "RowKey eq '$TenantId'"
        if (-not $Entity) { Write-Host "[FAIL] Tenant not found" -ForegroundColor Red; exit 1 }
        $Old = $Entity.GraphErrorCount
        $Entity.GraphErrorCount = 0
        Update-AzDataTableEntity @T -Entity $Entity
        Write-Host "[OK] GraphErrorCount: $Old -> 0 ($($Entity.displayName))" -ForegroundColor Green
    }

    'delete' {
        if (-not $TenantId) { Write-Host "[FAIL] -TenantId required" -ForegroundColor Red; exit 1 }
        $T = Get-TenantTable
        $Entity = Get-AzDataTableEntity @T -Filter "RowKey eq '$TenantId'"
        if (-not $Entity) { Write-Host "[FAIL] Tenant not found" -ForegroundColor Red; exit 1 }
        Write-Host "[WARN] Delete $($Entity.displayName) ($TenantId)? (y/N)" -ForegroundColor Red
        if ((Read-Host) -ne 'y') { Write-Host "Cancelled"; exit 0 }
        Remove-AzDataTableEntity @T -Entity $Entity
        Write-Host "[OK] Deleted" -ForegroundColor Green
    }

    'import' {
        if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) {
            Write-Host "[FAIL] -ConfigFile required" -ForegroundColor Red; exit 1
        }
        $Config = Get-Content $ConfigFile | ConvertFrom-Json
        $T = Get-TenantTable
        $Added = 0; $Skipped = 0
        foreach ($Tenant in $Config.tenants) {
            $Tid = $Tenant.tenantId
            $Existing = Get-AzDataTableEntity @T -Filter "RowKey eq '$Tid'"
            if ($Existing) {
                Write-Host "  [SKIP] $($Tenant.displayName) ($Tid)" -ForegroundColor DarkYellow
                $Skipped++
                continue
            }
            $Entity = @{
                PartitionKey             = 'Tenants'
                RowKey                   = $Tid
                displayName              = $Tenant.displayName
                defaultDomainName        = $Tenant.defaultDomain
                initialDomainName        = if ($Tenant.initialDomain) { $Tenant.initialDomain } else { $Tenant.defaultDomain }
                customerId               = $Tid
                delegatedPrivilegeStatus = 'directTenant'
                GraphErrorCount          = 0
            }
            Add-AzDataTableEntity @T -Entity $Entity -Force
            Write-Host "  [OK] $($Tenant.displayName) ($Tid)" -ForegroundColor Green
            $Added++
        }
        Write-Host ""
        Write-Host "Done: $Added added, $Skipped skipped" -ForegroundColor Cyan
    }
}
