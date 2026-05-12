# CIPP 平行租户（Direct Tenant）完整管理指南

## 三种租户接入模式

| 模式 | 场景 | 操作方式 | 复杂度 |
|------|------|---------|--------|
| **A. UI Setup Wizard** | 首次添加单个租户 | CIPP 网页 UI + OAuth 登录 | ⭐ |
| **B. Azurite 批量导入** | 批量添加/迁移租户 | PowerShell 脚本直接写入 Azurite | ⭐⭐ |
| **C. 独立 App Registration** | 每个租户独立应用（安全隔离） | PowerShell + Graph API | ⭐⭐⭐ |

---

## 模式 A：UI Setup Wizard（默认推荐）

### 完整流程

#### 第 1 步：进入 Setup Wizard
- 浏览器访问 `https://mtm.cxty.de/cipp/setup`
- 在选项列表中选择 **"Add a tenant"**（不是 "First Setup"）

#### 第 2 步：选择租户类型
- **"Direct"** — 平行租户模式（推荐）
- **"GDAP"** — GDAP 代理模式

#### 第 3 步：OAuth 授权
- 点击 **"Connect to Tenant"** 按钮
- 弹出 Microsoft OAuth 窗口
- 用**目标租户的全局管理员**账号登录
- 授权 CIPP-SAM 的委托权限
- 完成后 CIPP 自动写入 Azurite

#### 第 4 步：一键修复（Post-TenantSetup.ps1）
OAuth 完成后，**立即运行此脚本**完成所有后续修复：

```bash
cd /root/cipp-deploy/CIPP-API
pwsh -NoProfile -Command "& ./scripts/Post-TenantSetup.ps1 -TenantId '你的租户ID'"
```

脚本自动完成：
1. ✅ 验证租户记录是否写入 Azurite
2. ✅ 重置 GraphErrorCount（清除错误计数）
3. ✅ 验证 refresh token 是否已存储
4. ✅ 测试 ListUsers（用户查询）
5. ✅ 测试 ListLicenses（许可证查询）
6. ✅ 测试 ListGraphRequest（组织信息）
7. ✅ 最终清理（再次重置 GraphErrorCount）

#### 如果 Graph API 测试失败
说明管理员同意还未授予。在 Azure Portal 中：
1. 切换到目标租户
2. **应用注册** → CIPP-SAM → **API 权限**
3. 点击 **"授予管理员同意"**
4. 重新运行 `Post-TenantSetup.ps1`

### 底层流程
```
用户 OAuth 登录
    ↓
前端获取 accessToken + refreshToken
    ↓
POST /api/ExecAddTenant
    body: { tenantId, accessToken, refreshToken, ... }
    ↓
后端用 accessToken 调用 Graph API:
    GET /organization → 获取 displayName, tenantId
    GET /domains → 获取 defaultDomainName, initialDomainName
    ↓
写入 Azurite Tenants 表:
    PartitionKey: "Tenants"
    RowKey: tenantId
    delegatedPrivilegeStatus: "directTenant"
    GraphErrorCount: 0
    refreshToken: (加密存储)
    ↓
触发 Start-DurableCPVPermissionsTimer
    → Set-CIPPCPVConsent (推送 Service Principal + 授权应用权限)
    → Start-UpdateTokensTimer (定时刷新 refresh_token)
```

### 优点
- 简单、自动化
- 自动获取并存储 refresh_token
- 自动触发 CPV 权限推送

### 限制
- 需要浏览器访问
- 每次只能添加一个租户
- 需要目标租户的全局管理员在线操作

---

## 模式 B：Azurite 批量导入

### 适用场景
- 批量迁移租户
- 无浏览器访问时的紧急修复
- 恢复被删除的租户记录

### 使用方法

```powershell
# 列出所有租户
./scripts/Add-DirectTenant.ps1 -Action list

# 从 JSON 批量导入
./scripts/Add-DirectTenant.ps1 -Action import -ConfigFile ./scripts/tenants-sample.json

# 添加单个租户
./scripts/Add-DirectTenant.ps1 -Action add -TenantId "xxx" -DisplayName "Contoso" -DefaultDomain "contoso.onmicrosoft.com"

# 重置 GraphErrorCount
./scripts/Add-DirectTenant.ps1 -Action reset -TenantId "xxx"
```

### ⚠️ 重要限制
Azurite 直接写入**不会**获取 refresh_token！必须后续通过 UI Setup Wizard 补充 OAuth 授权，否则：
- 定时 token 刷新无法工作
- 委托式 Graph API 调用会失败
- CPV 权限推送可能失败

---

## 模式 C：独立 App Registration

### 适用场景
- 安全隔离：每个租户独立的应用凭据
- 合规要求：不允许跨租户共享应用
- 细粒度控制：每个租户不同的权限范围

### 使用方法

```powershell
# 前置条件：已通过模式 A 或 B 添加了租户
# 此脚本在目标租户中创建独立的 App Registration

./scripts/Setup-TenantAppRegistration.ps1 `
    -TenantId "xxx" `
    -AppDisplayName "CIPP-Management" `
    -CippAppId "98779b37-04c7-4714-887a-0c3bae41cb82"
```

### 后续步骤
创建 App Registration 后，还需要修改 CIPP 的 token 获取逻辑以支持 per-tenant 凭据。参见 `scripts/Patch-GraphTokenForModeC.ps1`。

---

## 监控与维护

### GraphErrorCount 健康检查

```powershell
# 检查所有租户健康状态
./scripts/Monitor-TenantHealth.ps1

# 自动修复异常租户
./scripts/Monitor-TenantHealth.ps1 -AutoFix

# 仅告警（不修复）
./scripts/Monitor-TenantHealth.ps1 -AlertOnly
```

### 关键指标
- `GraphErrorCount < 10`：正常
- `GraphErrorCount 10-49`：警告，需关注
- `GraphErrorCount >= 50`：**危险！** 租户会被 `Get-Tenants` 过滤掉，Dashboard 数据消失

### 手动重置（紧急）

```powershell
# 直接操作 Azurite 表存储
$ConnStr = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNoBnZf6KgBVU4=;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
Import-Module ./Modules/AzBobbyTables -Force
$Ctx = New-AzDataTableContext -ConnectionString $ConnStr -TableName "Tenants"
$Table = @{ Context = $Ctx }
$Entity = Get-AzDataTableEntity @Table -Filter "RowKey eq 'your-tenant-id'"
$Entity.GraphErrorCount = 0
Update-AzDataTableEntity @Table -Entity $Entity
```

---

## Azurite 表存储结构

### Tenants 表字段

| 字段 | 类型 | 说明 |
|------|------|------|
| PartitionKey | string | 固定值 "Tenants" |
| RowKey | string | tenantId (GUID) |
| displayName | string | 租户显示名称 |
| defaultDomainName | string | 默认域名 (xxx.onmicrosoft.com) |
| initialDomainName | string | 初始域名 |
| customerId | string | 客户 ID (= tenantId) |
| delegatedPrivilegeStatus | string | "directTenant" / "granularDelegatedAdminPrivileges" / "" |
| GraphErrorCount | int | Graph API 错误计数 |
| objectid | string | Service Principal 对象 ID |
| excludeDate | string | 排除日期（空=不排除） |
| excludeUser | string | 排除用户 |

### 连接信息
```
AccountName: devstoreaccount1
AccountKey:  Eby8vdM02xNoBnZf6KgBVU4=
TableEndpoint: http://127.0.0.1:10002/devstoreaccount1
```

---

## 新租户接入检查清单

- [ ] **1. 添加租户记录**（模式 A/B 选一）
  - [ ] A. UI Setup Wizard → Add a tenant → Direct → Connect to Tenant
  - [ ] B. Azurite 批量导入 + 后续补充 OAuth
- [ ] **2. 运行 Post-TenantSetup.ps1**（一键修复）
  - [ ] 验证租户写入 Azurite
  - [ ] 验证 refresh token 存储
  - [ ] 测试 Graph API（ListUsers, ListLicenses, ListGraphRequest）
  - [ ] 自动重置 GraphErrorCount
- [ ] **3. 如果 Graph API 失败：授予管理员同意**
  - [ ] Azure Portal → 应用注册 → CIPP-SAM → API 权限 → 授予管理员同意
  - [ ] 重新运行 Post-TenantSetup.ps1
- [ ] **4. 验证 Dashboard 数据**
  - [ ] 访问 CIPP 仪表板确认用户、许可证、组等数据正常显示
- [ ] **5. 设置监控**（可选）
  - [ ] 运行 `Monitor-TenantHealth.ps1` 确认状态正常
  - [ ] 配置定时任务监控 GraphErrorCount
