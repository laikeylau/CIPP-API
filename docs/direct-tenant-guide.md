# CIPP Direct Tenant 租户管理指南

## 概述

CIPP 支持两种租户管理模式：
- **GDAP（Granular Delegated Admin Privileges）**：通过 Partner Center 管理，适合 MSP 多租户场景
- **Direct Tenant（平行租户）**：每个租户独立 OAuth 授权，适合单租户或少量租户管理

本指南针对 **Direct Tenant** 模式，已在 Linux + cipp-server.ps1 本地服务器环境下验证通过。

## 前置条件

1. CIPP-SAM App Registration 已配置（见 root-level README）
2. CIPP API 服务器正在运行：`DisableCIPPRestMethod=true pwsh -File ./cipp-server.ps1`
3. Azurite 存储服务正在运行（用于存储租户和 token 数据）

## 新租户接入流程（4步完成）

### Step 1: 在 Setup Wizard 中选择 "Add a tenant"

打开 CIPP 仪表板 → Setup Wizard → 选择 **"Add a tenant"**（不是 "First Setup"）

### Step 2: 选择租户类型 "Direct"

选择 **Direct** — 平行租户模式（每租户独立 OAuth）

### Step 3: OAuth 授权

点击 **"Connect to Tenant"** 按钮：
1. 弹出 Microsoft OAuth 窗口
2. 用目标租户的**全局管理员**账号登录
3. 授权 CIPP-SAM 的委托权限
4. 授权完成后页面会自动跳转

### Step 4: 一键验证修复

OAuth 完成后，运行一键修复脚本：

```bash
cd /root/cipp-deploy/CIPP-API
pwsh -NoProfile -Command "& ./scripts/Post-TenantSetup.ps1 -TenantId '<租户ID>'"
```

脚本会自动完成：
1. ✅ 验证租户是否写入 Azurite
2. ✅ 重置 GraphErrorCount
3. ✅ 验证 refresh token 是否存储
4. ✅ 测试 Graph API（ListUsers、ListLicenses、ListGraphRequest）
5. ✅ **同步报告数据库**（Mailboxes + MailboxPermissions + CalendarPermissions）
6. ✅ 测试 Exchange Online（ListMailboxes）
7. ✅ 最终清理

**如果 Exchange Online 测试失败（403 Forbidden）：**
需要在目标租户为 CIPP-SAM 分配 Exchange Administrator 角色：
1. 登录 Azure Portal → 切换到目标租户
2. Enterprise Applications → 搜索 CIPP-SAM
3. Users and groups → Add user/group
4. 选择角色: **Exchange Administrator** → Assign
5. 重新运行脚本验证

## 环境信息

| 项目 | 值 |
|------|-----|
| CIPP-SAM AppId | 98779b37-04c7-4714-887a-0c3bae41cb82 |
| Host Tenant | 2b2ccf22-1af7-4ef4-a191-ad9b9a3b5de1 (SYSTEX) |
| API Base URL | http://localhost:7071 |
| Azurite Table | Tenants (PartitionKey: Tenants, RowKey: customerId) |
| Token Storage | DevSecrets (PartitionKey: Secret, RowKey: Secret) |

## 已验证租户

| 租户 | TenantId | 状态 |
|------|----------|------|
| demfre05outlook.onmicrosoft.com | 15dc8949-c50b-438d-9a9a-26fe501c5895 | ✅ 完全正常 |
| lenitech.onmicrosoft.com | 2df8b2f9-1714-4246-825d-d655b1577ec3 | ✅ 完全正常 |

## 脚本清单

| 脚本 | 用途 |
|------|------|
| `Post-TenantSetup.ps1` | **推荐** OAuth 后一键修复（Graph + EXO + 权限同步全测试） |
| `Sync-AllCache.ps1` | **推荐** 全量缓存同步（72 类型，覆盖 Dashboard/Identity/Exchange/SharePoint/Intune/Security/Copilot/PIM/Compliance） |
| `Sync-ReportData.ps1` | 同步报告数据库（邮箱、权限、日历权限、规则） |
| `Add-DirectTenant.ps1` | 租户管理（list/add/import/reset） |
| `Monitor-TenantHealth.ps1` | 健康监控 |

## 许可证相关功能限制

以下功能需要额外的 Microsoft 365 许可证：

| 功能 | 需要的许可证 |
|------|-------------|
| Intune / Autopilot | Microsoft Intune Plan 1/2 |
| Defender TVM | Microsoft Defender for Endpoint Plan 2 |
| Safe Links / MDO | Microsoft Defender for Office 365 |
| Security Incidents | Microsoft 365 Defender |

## 常见问题

### Q: Graph API 超时或返回 AADSTS 错误？
A: 运行 `Post-TenantSetup.ps1`，脚本会自动重置 GraphErrorCount 并测试连接。

### Q: 邮箱功能报 403 Forbidden？
A: 在目标租户为 CIPP-SAM 分配 Exchange Administrator 角色（见 Step 4 说明）。

### Q: 如何检查租户状态？
A: 运行 `./scripts/Monitor-TenantHealth.ps1` 或 `./scripts/Add-DirectTenant.ps1 -Action list`

### Q: 如何重置某个租户的错误计数？
A: 运行 `./scripts/Add-DirectTenant.ps1 -Action reset -TenantId '<租户ID>'`

### Q: 日历权限页面显示空数组？
A: 这是预期行为。`ListCalendarPermissions` 会过滤掉默认权限（Default/Anonymous），只显示自定义权限。如果租户没有自定义日历权限，返回 `[]` 是正确的。

### Q: 如何手动同步报告数据？
A: 运行 `./scripts/Sync-ReportData.ps1 -TenantFilter '<租户域名>' -Types 'All'`，支持的类型包括：
- `Mailboxes` — 邮箱列表
- `Permissions` — 邮箱权限（FullAccess、SendAs、SendOnBehalf）
- `CalendarPermissions` — 日历权限
- `Rules` — 邮箱规则

### Q: 如何同步所有租户的全量缓存数据？
A: 运行 `./scripts/Sync-AllCache.ps1`，支持以下参数：
- `-TenantFilter '<租户ID>'` — 只同步指定租户
- `-SkipExisting` — 跳过已有数据的租户（增量同步）
- `-Categories 'Dashboard,Identity,Exchange'` — 只同步指定分类

**示例：**
```bash
# 同步所有活跃租户（完整）
pwsh -File ./scripts/Sync-AllCache.ps1

# 只同步指定租户
pwsh -File ./scripts/Sync-AllCache.ps1 -TenantFilter '2df8b2f9-1714-4246-825d-d655b1577ec3'

# 增量同步（跳过已有数据）
pwsh -File ./scripts/Sync-AllCache.ps1 -SkipExisting
```

**支持的分类：**
- `Dashboard` — Users, Guests, Groups, Devices, SecureScore, MFA, LicenseOverview
- `Identity` — RiskyUsers, RiskDetections, CredentialUserRegistrationDetails, ServicePrincipals, Apps
- `Exchange` — Mailboxes, CASMailboxes, MailboxUsage, TransportRules, AntiSpam/Phish/Malware policies
- `SharePoint` — SharePointSiteUsage, OneDriveUsage
- `Intune` — ManagedDevices, DeviceCompliance, DeviceConfigurations, DetectedApps
- `Security` — ConditionalAccessPolicies, AuthorizationPolicy, CrossTenantAccessPolicy, B2BManagementPolicy
- `Copilot` — CopilotReadinessActivity, CopilotUsageUserDetail
- `PIM` — Roles, PIMSettings, RoleAssignmentScheduleInstances, RoleEligibilitySchedules
- `Compliance` — BitlockerKeys, MDEOnboarding, DirectoryRecommendations
- `Other` — Domains, Settings, Organization, OfficeActivations

### Q: 如何设置定时任务自动同步？
A: 使用 Hermes cronjob 设置定时任务，例如每6小时同步一次：
```bash
# 创建定时任务
hermes cronjob create --name "CIPP Full Cache Sync" --schedule "0 */6 * * *" --command "cd /root/cipp-deploy/CIPP-API && pwsh -File scripts/Sync-AllCache.ps1"
```
