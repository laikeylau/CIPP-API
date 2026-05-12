# CIPP Direct Tenant Management Scripts

## 脚本清单

| 脚本 | 用途 | 模式 |
|------|------|------|
| `Post-TenantSetup.ps1` | **一键修复**：OAuth 添加租户后自动验证+修复 | A（推荐） |
| `Add-DirectTenant.ps1` | 批量添加/管理 Azurite 中的租户记录 | B |
| `Setup-TenantAppRegistration.ps1` | 为租户创建独立 App Registration | C |
| `Patch-GraphTokenForModeC.ps1` | 修改 CIPP token 逻辑支持独立凭据 | C |
| `Monitor-TenantHealth.ps1` | 监控所有租户健康状态 + 自动修复 | 通用 |

## 快速开始

### 新租户接入（推荐流程）

```bash
# 1. 在 CIPP UI 完成 OAuth 添加（Setup Wizard → Add a tenant → Direct → Connect to Tenant）

# 2. 一键修复（验证 + 重置 + 测试）
cd /root/cipp-deploy/CIPP-API
pwsh -NoProfile -Command "& ./scripts/Post-TenantSetup.ps1 -TenantId '你的租户ID'"
```

### 检查当前状态
```bash
cd /root/cipp-deploy/CIPP-API
pwsh -File scripts/Add-DirectTenant.ps1 -Action list
```

### 批量添加租户
```bash
# 1. 编辑配置文件
cp scripts/tenants-sample.json scripts/my-tenants.json
vim scripts/my-tenants.json

# 2. 执行导入
pwsh -File scripts/Add-DirectTenant.ps1 -Action import -ConfigFile scripts/my-tenants.json
```

### 修复被阻断的租户
```bash
# 重置单个租户
pwsh -File scripts/Add-DirectTenant.ps1 -Action reset -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# 重置所有阻断的租户
pwsh -File scripts/Add-DirectTenant.ps1 -ResetErrorCount
```

### 健康监控
```bash
# 仅检查
pwsh -File scripts/Monitor-TenantHealth.ps1

# 检查 + 自动修复
pwsh -File scripts/Monitor-TenantHealth.ps1 -AutoFix

# 检查 + 修复 + Teams 告警
pwsh -File scripts/Monitor-TenantHealth.ps1 -AutoFix -TeamsAlert
```

### 独立 App Registration (Mode C)
```bash
# 为租户创建独立 App
pwsh -File scripts/Setup-TenantAppRegistration.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# 修改 CIPP token 逻辑支持独立凭据
pwsh -File scripts/Patch-GraphTokenForModeC.ps1

# 撤销修改
pwsh -File scripts/Patch-GraphTokenForModeC.ps1 -Revert
```

## 配合 Cron 定时监控

在 Hermes Agent 中设置定时任务：
```
cronjob create --name "CIPP Health Monitor" --schedule "0 */6 * * *" \
  --script "/root/cipp-deploy/CIPP-API/scripts/Monitor-TenantHealth.ps1 -AutoFix -TeamsAlert"
```

## 文档

完整指南参见：`/root/cipp-deploy/CIPP-API/docs/direct-tenant-guide.md`
