#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Patch Get-GraphToken.ps1 to support per-tenant App Registration (Mode C)
    为 Mode C 场景修改 CIPP 的 token 获取逻辑

.DESCRIPTION
    修改 Get-GraphToken.ps1，使其在 directTenant 模式下优先检查
    DevSecrets 表中是否有该租户独立的 AppId/AppSecret。
    如果有，则使用独立凭据进行 app-only 认证。

.NOTES
    此脚本会修改 CIPP-API 核心文件。建议先备份。
    运行前确保 CIPP API 服务已停止。
#>

param(
    [switch]$Revert,
    [string]$CippApiPath = "/root/cipp-deploy/CIPP-API"
)

$ErrorActionPreference = "Stop"
$TargetFile = Join-Path $CippApiPath "Modules/CIPPCore/Public/GraphHelper/Get-GraphToken.ps1"

if (-not (Test-Path $TargetFile)) {
    Write-Host "❌ File not found: $TargetFile" -ForegroundColor Red
    exit 1
}

$BackupFile = "$TargetFile.bak"

# ── Revert if requested ──
if ($Revert) {
    if (Test-Path $BackupFile) {
        Copy-Item $BackupFile $TargetFile -Force
        Write-Host "✅ Reverted to backup" -ForegroundColor Green
    } else {
        Write-Host "❌ No backup found at $BackupFile" -ForegroundColor Red
    }
    return
}

# ── Backup ──
if (-not (Test-Path $BackupFile)) {
    Copy-Item $TargetFile $BackupFile -Force
    Write-Host "✅ Backup created: $BackupFile" -ForegroundColor Green
}

# ── Read current content ──
$Content = Get-Content $TargetFile -Raw

# ── Check if already patched ──
if ($Content -match "per-tenant app registration support") {
    Write-Host "⚠️ Already patched. Use -Revert to undo." -ForegroundColor Yellow
    return
}

# ── Patch: Add per-tenant credential lookup before the auth body construction ──
$PatchMarker = @"
    # ── [PATCH] Per-tenant app registration support (Mode C) ──
    # Check if this directTenant has its own AppId/AppSecret in DevSecrets
    if ($tenantid -ne $env:TenantID -and $clientType.delegatedPrivilegeStatus -eq 'directTenant') {
        `$SafeTenantId = $clientType.customerId -replace '-', '_'
        `$PerTenantAppId = `$null
        `$PerTenantAppSecret = `$null

        if (`$env:AzureWebJobsStorage -eq 'UseDevelopmentStorage=true' -or `$env:NonLocalHostAzurite -eq 'true') {
            `$SecretTable = Get-CIPPTable -tablename 'DevSecrets'
            `$SecretData = Get-CIPPAzDataTableEntity @`$SecretTable -Filter "PartitionKey eq 'Secret' and RowKey eq 'Secret'" -ErrorAction SilentlyContinue
            if (`$SecretData) {
                `$PerTenantAppId = `$SecretData."AppId_`$SafeTenantId"
                `$PerTenantAppSecret = `$SecretData."AppSecret_`$SafeTenantId"
            }
        }

        if (`$PerTenantAppId -and `$PerTenantAppSecret) {
            Write-Host "Using per-tenant App Registration for `$($clientType.customerId) (AppId: `$PerTenantAppId)"
            `$AppID = `$PerTenantAppId
            `$AppSecret = `$PerTenantAppSecret
            `$asApp = `$true
        }
    }
    # ── [END PATCH] ──

"@

# ── Find the insertion point: after the refreshToken fallback to asApp ──
$InsertAfter = '# If no refresh token available for direct tenant, fall back to app-only (client_credentials)
        if ([string]::IsNullOrEmpty($refreshToken)) {
            $asApp = $true
        }'

if ($Content -notmatch [regex]::Escape($InsertAfter)) {
    Write-Host "❌ Could not find insertion point in file" -ForegroundColor Red
    Write-Host "Expected: $InsertAfter" -ForegroundColor DarkGray
    exit 1
}

$Content = $Content.Replace($InsertAfter, $InsertAfter + "`n" + $PatchMarker)

# ── Write patched file ──
Set-Content $TargetFile $Content -NoNewline
Write-Host "✅ Patched Get-GraphToken.ps1" -ForegroundColor Green
Write-Host "   Per-tenant AppId/AppSecret lookup added for directTenant mode" -ForegroundColor DarkGray
Write-Host "   Backup: $BackupFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "To revert: ./Patch-GraphTokenForModeC.ps1 -Revert" -ForegroundColor Yellow
