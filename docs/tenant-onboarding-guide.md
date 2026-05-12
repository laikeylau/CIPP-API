# CIPP 租户接入操作指南（三种方式）

## 概述

CIPP 支持 **Direct Tenant（平行租户）** 模式管理 Microsoft 365 租户。本指南介绍三种添加新租户的完整流程，确保权限不遗漏。

---

## 前置条件

| 项目 | 状态 |
|------|------|
| CIPP API 服务器 | 运行中（`http://localhost:7071`） |
| Azurite 存储 | 运行中（端口 10000/10001/10002） |
| CIPP-SAM App Registration | 已配置（见 `permission-fix-guide.md`） |
| 目标租户全局管理员 | 可登录并授权 |

---

## 方式一：Web UI（推荐用于单个租户）

通过 CIPP 仪表板的 Setup Wizard 添加。

### 步骤

1. **打开 CIPP 仪表板** → `https://mtm.cxty.de`
2. **Setup Wizard** → 选择 **"Add a tenant"**
3. **选择租户类型** → 选择 **"Direct"**（平行租户模式）
4. **OAuth 授权** → 点击 **"Connect to Tenant"**
   - 弹出 Microsoft OAuth 窗口
   - 用目标租户的**全局管理员**账号登录
   - 授权 CIPP-SAM 的所有权限
   - 授权完成后页面自动跳转
5. **配置权限** → 运行权限设置脚本：

```bash
cd /root/cipp-deploy/CIPP-API
pwsh -File ./scripts/Setup-TenantPermissions.ps1 -TenantId '<租户ID>'
```

6. **激活权限** → 运行 Admin Consent：

```
https://login.microsoftonline.com/<租户ID>/adminconsent?client_id=98779b37-04c7-4714-887a-0c3bae41cb82&redirect_uri=https://mtm.cxty.de/authredirect
```

7. **验证** → 运行验证脚本：

```bash
pwsh -File ./scripts/Post-TenantSetup.ps1 -TenantId '<租户ID>'
```

### 适用场景
- 首次接入新租户
- 需要 OAuth 授权（获取 refresh_token）
- 管理员可操作浏览器

---

## 方式二：CLI 单租户添加

通过命令行脚本直接添加，无需 Web UI。

### 步骤

1. **添加租户并自动配置权限**：

```bash
cd /root/cipp-deploy/CIPP-API
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action add \
  -TenantId '<租户ID>' \
  -DisplayName '<租户名称>' \
  -DefaultDomain '<默认域名>'
```

示例：
```bash
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action add \
  -TenantId '2df8b2f9-1714-4246-825d-d655b1577ec3' \
  -DisplayName 'Lenit Tech' \
  -DefaultDomain 'lenitech.onmicrosoft.com'
```

脚本会自动：
- ✅ 写入 Azurite Tenants 表
- ✅ 调用 `Setup-TenantPermissions.ps1` 配置全部权限（59 Graph + 2 EXO + Exchange Admin 角色）

2. **获取 OAuth Token** → 需要通过 Web UI 或手动 Admin Consent 获取 refresh_token：

```
https://login.microsoftonline.com/<租户ID>/adminconsent?client_id=98779b37-04c7-4714-887a-0c3bae41cb82&redirect_uri=https://mtm.cxty.de/authredirect
```

3. **验证**：

```bash
pwsh -File ./scripts/Post-TenantSetup.ps1 -TenantId '<租户ID>'
```

### 适用场景
- 批量部署时的单租户添加
- 自动化脚本集成
- 租户记录已存在但需要重新配置权限

---

## 方式三：CLI 批量导入

通过 JSON 配置文件批量添加多个租户。

### 步骤

1. **创建 JSON 配置文件**：

```json
{
  "tenants": [
    {
      "tenantId": "aaaa-bbbb-cccc-dddd",
      "displayName": "Contoso Ltd",
      "defaultDomain": "contoso.onmicrosoft.com",
      "initialDomain": "contoso.onmicrosoft.com"
    },
    {
      "tenantId": "eeee-ffff-gggg-hhhh",
      "displayName": "Fabrikam Inc",
      "defaultDomain": "fabrikam.onmicrosoft.com",
      "initialDomain": "fabrikam.onmicrosoft.com"
    }
  ]
}
```

2. **批量导入**：

```bash
cd /root/cipp-deploy/CIPP-API
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action import -ConfigFile ./tenants.json
```

3. **逐个配置权限**（导入不会自动调用权限脚本）：

```bash
# 对每个新导入的租户运行
pwsh -File ./scripts/Setup-TenantPermissions.ps1 -TenantId '<租户ID1>'
pwsh -File ./scripts/Setup-TenantPermissions.ps1 -TenantId '<租户ID2>'
```

4. **逐个完成 OAuth 授权**：

```
https://login.microsoftonline.com/<租户ID>/adminconsent?client_id=98779b37-04c7-4714-887a-0c3bae41cb82&redirect_uri=https://mtm.cxty.de/authredirect
```

5. **批量验证**：

```bash
for tid in "<tenant1>" "<tenant2>"; do
  pwsh -File ./scripts/Post-TenantSetup.ps1 -TenantId "$tid"
done
```

### 适用场景
- 大量租户的初始导入
- 迁移场景
- 标准化部署

---

## 权限清单

`Setup-TenantPermissions.ps1` 自动配置以下权限：

### Microsoft Graph（59 项）
- Identity: User, Group, Directory, Domain, Organization
- Security: SecurityAlert, SecurityEvents, ConditionalAccess, RiskyUsers
- Device Management: Apps, Configuration, ManagedDevices, RBAC, Scripts
- Exchange: Mail.ReadWrite, Mail.Send, MailboxSettings, Calendars, Contacts
- SharePoint: Sites.FullControl, Sites.ReadWrite
- Teams: Team, TeamMember, TeamSettings
- Audit: AuditLog, Reports
- Admin: RoleManagement, AppRoleAssignment, Application, DelegatedAdminRelationship

### Office 365 Exchange Online（2 项）
- Exchange.ManageAsApp
- Exchange.ManageAsAppV2

### Directory Roles（1 项）
- Exchange Administrator

---

## 常用管理命令

```bash
# 列出所有租户
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action list

# 重置租户错误计数
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action reset -TenantId '<租户ID>'

# 删除租户
pwsh -File ./scripts/Add-DirectTenant.ps1 -Action delete -TenantId '<租户ID>'

# 预览权限变更（不实际执行）
pwsh -File ./scripts/Setup-TenantPermissions.ps1 -TenantId '<租户ID>' -DryRun

# 全量缓存同步
pwsh -File ./scripts/Sync-AllCache.ps1

# 单租户同步
pwsh -File ./scripts/Sync-AllCache.ps1 -TenantFilter '<租户ID>'

# 健康检查
pwsh -File ./scripts/Monitor-TenantHealth.ps1
```

---

## 故障排除

| 问题 | 解决方案 |
|------|----------|
| Graph API 超时 / AADSTS 错误 | `Add-DirectTenant.ps1 -Action reset -TenantId '<ID>'` |
| 邮箱功能 403 Forbidden | 确认 Exchange Administrator 角色已分配（`Setup-TenantPermissions.ps1` 自动处理） |
| IdentityRiskyUser 权限缺失 | 运行 `Setup-TenantPermissions.ps1` 后重新 Admin Consent |
| Dashboard 数据为空 | 运行 `Sync-AllCache.ps1` 同步缓存 |
| 租户不显示在列表中 | 检查 `GraphErrorCount` 是否 >= 50，运行 reset |
