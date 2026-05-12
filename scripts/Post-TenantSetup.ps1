#!/usr/bin/env pwsh
<#
.SYNOPSIS
    CIPP 租户添加后一键修复 — 在 OAuth 添加租户（Step 3）后运行此脚本
    自动完成：验证租户、重置 GraphErrorCount、测试 Graph API、测试 Exchange Online

.PARAMETER TenantId
    目标租户的 tenant ID（必填）

.PARAMETER TenantFilter
    租户域名或 tenant ID（用于 CIPP API 调用，默认与 TenantId 相同）

.PARAMETER SkipGraphTest
    跳过 Graph API 测试

.PARAMETER SkipExoTest
    跳过 Exchange Online 测试

.EXAMPLE
    ./Post-TenantSetup.ps1 -TenantId "15dc8949-c50b-438d-9a9a-26fe501c5895"
    ./Post-TenantSetup.ps1 -TenantId "15dc8949-c50b-438d-9a9a-26fe501c5895" -SkipExoTest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    [string]$TenantFilter = "",
    [switch]$SkipGraphTest,
    [switch]$SkipExoTest
)

$ErrorActionPreference = 'Stop'
$CIPPBaseUrl = "http://localhost:7071"
if (-not $TenantFilter) { $TenantFilter = $TenantId }

# ─── Load AzBobbyTables ──────────────────────────────────────────────────────
Import-Module "$PSScriptRoot/../Modules/AzBobbyTables" -Force
$ConnStr = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"

function Get-TenantTable {
    $Ctx = New-AzDataTableContext -ConnectionString $ConnStr -TableName "Tenants"
    @{ Context = $Ctx }
}

function Get-SecretTable {
    $Ctx = New-AzDataTableContext -ConnectionString $ConnStr -TableName "DevSecrets"
    @{ Context = $Ctx }
}

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Step. $Message" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}
function Write-OK    { param([string]$Msg) Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "  ❌ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ️  $Msg" -ForegroundColor Gray }

function Invoke-CippApi {
    param([string]$Endpoint, [string]$Method = "GET", [hashtable]$Body = $null)
    $url = "$CIPPBaseUrl/api/$Endpoint"
    try {
        $params = @{ Uri = $url; Method = $Method; ContentType = "application/json"; TimeoutSec = 120; ErrorAction = "Stop" }
        if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
        $resp = Invoke-RestMethod @params
        return @{ Success = $true; Data = $resp }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# ─── Pre-flight ──────────────────────────────────────────────────────────────
Write-Host "`n🔧 CIPP Post-Tenant Setup — 一键修复" -ForegroundColor White
Write-Host "   租户 ID: $TenantId" -ForegroundColor Gray

Write-Step "0" "前置检查"
try {
    $null = Invoke-RestMethod -Uri "$CIPPBaseUrl/api/ExecListAppId" -TimeoutSec 30 -ErrorAction Stop
    Write-OK "CIPP API 运行正常"
} catch {
    if ($_.Exception.Message -match "timeout|canceled") {
        Write-OK "CIPP API 运行正常（服务器繁忙，但可访问）"
    } else {
        Write-Fail "CIPP API 未运行！请先启动：cd /root/cipp-deploy/CIPP-API && DisableCIPPRestMethod=true pwsh -File ./cipp-server.ps1"
        exit 1
    }
}

# ─── Step 1: Verify tenant in Azurite ────────────────────────────────────────
Write-Step "1" "验证租户是否已写入 Azurite Tenants 表"

$T = Get-TenantTable
$allTenants = Get-AzDataTableEntity @T
$tenantEntity = $allTenants | Where-Object { $_.RowKey -eq $TenantId }

if ($tenantEntity) {
    Write-OK "租户记录存在"
    $displayName = $tenantEntity.displayName
    $defaultDomain = $tenantEntity.defaultDomainName
    $graphErrorCount = $tenantEntity.GraphErrorCount
    Write-Info "displayName: $displayName"
    Write-Info "defaultDomain: $defaultDomain"
    Write-Info "GraphErrorCount: $graphErrorCount"

    if ($graphErrorCount -gt 0) {
        Write-Warn "GraphErrorCount=$graphErrorCount，正在重置为 0..."
        $tenantEntity.GraphErrorCount = 0
        Update-AzDataTableEntity @T -Entity $tenantEntity | Out-Null
        Write-OK "GraphErrorCount 已重置为 0"
    } else {
        Write-OK "GraphErrorCount=0，无需重置"
    }
} else {
    Write-Fail "租户记录不存在！请先通过 CIPP UI 完成 OAuth 添加（Step 3）"
    Write-Info "已有租户:"
    $allTenants | Where-Object { $_.PartitionKey -eq 'Tenants' } | ForEach-Object {
        Write-Info "  - $($_.displayName) ($($_.RowKey))"
    }
    exit 1
}

# ─── Step 2: Verify refresh token ────────────────────────────────────────────
Write-Step "2" "验证 refresh token 是否已存储"

$S = Get-SecretTable
$allSecrets = Get-AzDataTableEntity @S
$secretEntity = $allSecrets | Where-Object { $_.RowKey -eq 'Secret' }
$tokenPropName = $TenantId.Replace("-", "_")

if ($secretEntity -and $secretEntity.$tokenPropName) {
    $tokenLen = $secretEntity.$tokenPropName.Length
    Write-OK "Refresh token 存在 (属性: $tokenPropName, 长度: $tokenLen 字符)"
} else {
    Write-Fail "Refresh token 未找到！请重新通过 CIPP UI 完成 OAuth 授权"
    Write-Info "期望属性名: $tokenPropName"
    exit 1
}

# ─── Step 3: Test Graph API connectivity ─────────────────────────────────────
Write-Step "3" "测试 Graph API 连接"

if ($SkipGraphTest) {
    Write-Info "已跳过（-SkipGraphTest）"
} else {
    $testsPassed = 0
    $testsFailed = 0

    # Test 1: ListUsers
    Write-Info "测试 ListUsers..."
    $usersResult = Invoke-CippApi -Endpoint "ListUsers?TenantFilter=$TenantFilter"
    if ($usersResult.Success) {
        $userCount = @($usersResult.Data).Count
        if ($userCount -gt 0) {
            Write-OK "ListUsers: 返回 $userCount 个用户"
            $testsPassed++
        } else {
            Write-Warn "ListUsers: 返回空数据"
            $testsFailed++
        }
    } else {
        Write-Fail "ListUsers 失败: $($usersResult.Error)"
        $testsFailed++
    }

    # Test 2: ListLicenses
    Write-Info "测试 ListLicenses..."
    $licenseResult = Invoke-CippApi -Endpoint "ListLicenses?TenantFilter=$TenantFilter"
    if ($licenseResult.Success) {
        $licenseCount = @($licenseResult.Data).Count
        if ($licenseCount -gt 0) {
            Write-OK "ListLicenses: 返回 $licenseCount 个许可证"
            $testsPassed++
        } else {
            Write-Warn "ListLicenses: 返回空数据（可能没有许可证）"
        }
    } else {
        Write-Fail "ListLicenses 失败: $($licenseResult.Error)"
        $testsFailed++
    }

    # Test 3: ListGraphRequest (organization)
    Write-Info "测试 ListGraphRequest (organization)..."
    $orgResult = Invoke-CippApi -Endpoint "ListGraphRequest?TenantFilter=$TenantFilter&endpoint=organization"
    if ($orgResult.Success) {
        $orgData = $orgResult.Data
        if ($orgData) {
            $orgName = if ($orgData -is [array]) { $orgData[0].displayName } else { $orgData.displayName }
            Write-OK "ListGraphRequest: 组织名 = $orgName"
            $testsPassed++
        } else {
            Write-Warn "ListGraphRequest: 返回空数据"
            $testsFailed++
        }
    } else {
        Write-Fail "ListGraphRequest 失败: $($orgResult.Error)"
        $testsFailed++
    }

    Write-Host ""
    if ($testsFailed -eq 0) {
        Write-OK "所有 Graph API 测试通过 ($testsPassed/$testsPassed)"
    } else {
        Write-Warn "Graph API 测试: $testsPassed 通过, $testsFailed 失败"
        Write-Info "如果 Graph API 失败，请在 Azure Portal 中为 CIPP-SAM 授予管理员同意"
        Write-Info "然后重新运行此脚本"
    }
}

# ─── Step 4: Test Exchange Online ────────────────────────────────────────────
Write-Step "4" "测试 Exchange Online 连接"

if ($SkipExoTest) {
    Write-Info "已跳过（-SkipExoTest）"
} else {
    Write-Info "测试 ListMailboxes..."
    $mailboxResult = Invoke-CippApi -Endpoint "ListMailboxes?TenantFilter=$TenantFilter"
    if ($mailboxResult.Success) {
        $data = $mailboxResult.Data
        if ($data -is [array] -and $data.Count -gt 0) {
            # Check if first item is an error string
            if ($data[0] -is [string] -and $data[0] -match "error|forbidden|403|not provisioned") {
                Write-Fail "ListMailboxes 失败: $($data[0])"
                Write-Host ""
                Write-Warn "Exchange Online 需要额外配置："
                Write-Info "  在目标租户的 Azure Portal 中为 CIPP-SAM 分配 Exchange Administrator 角色："
                Write-Info "  1. 登录 Azure Portal → 切换到目标租户"
                Write-Info "  2. Enterprise Applications → 搜索 CIPP-SAM"
                Write-Info "  3. Users and groups → Add user/group"
                Write-Info "  4. 选择角色: Exchange Administrator → Assign"
            } else {
                $mbxCount = $data.Count
                Write-OK "ListMailboxes: 返回 $mbxCount 个邮箱"
                $data | Select-Object -First 3 | ForEach-Object {
                    $upn = $_.UPN ?? $_.UserPrincipalName ?? "N/A"
                    $type = $_.recipientTypeDetails ?? "N/A"
                    Write-Info "  - $upn [$type]"
                }
                if ($mbxCount -gt 3) { Write-Info "  ... 还有 $($mbxCount - 3) 个" }
            }
        } else {
            Write-Warn "ListMailboxes: 返回空数据（租户可能没有邮箱）"
        }
    } else {
        Write-Fail "ListMailboxes 失败: $($mailboxResult.Error)"
        Write-Host ""
        Write-Warn "Exchange Online 需要额外配置："
        Write-Info "  在目标租户的 Azure Portal 中为 CIPP-SAM 分配 Exchange Administrator 角色："
        Write-Info "  1. 登录 Azure Portal → 切换到目标租户"
        Write-Info "  2. Enterprise Applications → 搜索 CIPP-SAM"
        Write-Info "  3. Users and groups → Add user/group"
        Write-Info "  4. 选择角色: Exchange Administrator → Assign"
    }
}

# ─── Step 5: Final status ────────────────────────────────────────────────────
Write-Step "5" "清理 & 最终状态"

# Reset GraphErrorCount one more time (Graph API tests may have incremented it)
$T = Get-TenantTable
$finalTenant = (Get-AzDataTableEntity @T) | Where-Object { $_.RowKey -eq $TenantId }
if ($finalTenant -and $finalTenant.GraphErrorCount -gt 0) {
    Write-Info "GraphErrorCount 被测试累积到 $($finalTenant.GraphErrorCount)，重置为 0..."
    $finalTenant.GraphErrorCount = 0
    Update-AzDataTableEntity @T -Entity $finalTenant | Out-Null
    Write-OK "GraphErrorCount 已重置为 0"
}
if ($finalTenant) {
    Write-OK "租户信息:"
    Write-Info "  displayName:      $($finalTenant.displayName)"
    Write-Info "  defaultDomain:    $($finalTenant.defaultDomainName)"
    Write-Info "  customerId:       $($finalTenant.customerId)"
    Write-Info "  GraphErrorCount:  $($finalTenant.GraphErrorCount)"
}

Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✅ 租户设置完成！现在可以在 CIPP 仪表板中管理此租户" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
