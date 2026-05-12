# CIPP Direct Tenant 权限修复
# 修复两个问题：
# 1. IdentityRiskyUser.Read.All (Risky Users)
# 2. Exchange Administrator directory role (EXO API)

## 已完成

### ✅ IdentityRiskyUser.Read.All 已添加到 App Registration
- AppId: 98779b37-04c7-4714-887a-0c3bae41cb82
- 已在 SYSTEX 租户的应用注册中声明此 Application 权限
- **需要你在 Lenit Tech 租户中重新授权才能生效**

### ⚠️ Exchange Administrator Directory Role
- Graph API 的 `directoryScope: "/"` 参数在 Lenit Tech 租户中始终报 schema 错误
- 这是该租户的特定问题（可能与 multi-tenant app 的 SP 有关）
- **需要在 Azure Portal 手动分配**

## 你需要做的

### 步骤1：重新授权（获取 IdentityRiskyUser.Read.All）
在浏览器中访问以下 URL：
```
https://login.microsoftonline.com/2df8b2f9-1714-4246-825d-d655b1577ec3/adminconsent?client_id=98779b37-04c7-4714-887a-0c3bae41cb82&redirect_uri=https://mtm.cxty.de/authredirect
```
- 用 Lenit Tech 的 Global Admin 账号登录
- 点击"Accept"授权所有权限
- 授权完成后，IdentityRiskyUser.Read.All 将自动生效

### 步骤2：手动分配 Exchange Administrator 角色
1. 打开 https://entra.microsoft.com
2. 切换到 Lenit Tech 租户
3. 导航到：**Entra ID** > **Roles and administrators**
4. 搜索 **Exchange Administrator**
5. 点击 **Add assignments**
6. 搜索并选择 **CIPP-SAM**
7. 点击 **Add**

## 修复后的效果
- Risky Users 页面将正常显示数据
- Exchange Online (EXO) 相关功能将正常工作（需要 Exchange Admin 角色）
- Dashboard 上的邮箱/EXO 相关 widget 将正常显示

## 未来新租户接入时
添加新租户后，运行以下脚本自动处理权限：
```pwsh
/root/cipp-deploy/CIPP-API/scripts/Fix-CIPPTenantPermissions.ps1 -TenantId <新租户ID>
```
如果脚本无法自动完成，会输出需要手动操作的步骤。
