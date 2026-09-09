# sohun 部署清单

## 1. API 服务

在服务器上运行 `电脑软件/community_server`，生产环境至少配置：

当前源码要求 community 数据库完成 migration **27**。migration 27 新增
`personal_stock_receipt_items`，用于同一张 CUID/FUID 资料卡多次批量入库的不可变回执；
部署前必须先在隔离副本预演迁移并通过 `PRAGMA integrity_check`，不能把 NTAG213 设备标签
数据写入个人库存快照或事件接口。

```powershell
$env:NODE_ENV = 'production'
$env:COMMUNITY_PUBLIC_BASE_URL = 'https://api.sohun.top'
$env:COMMUNITY_ALLOWED_ORIGIN = 'https://sohun.top'
$env:COMMUNITY_APP_LATEST_VERSION = 'v1.0.0'
$env:COMMUNITY_APP_GITHUB_REPOSITORY = '你的账号/你的仓库'
$env:COMMUNITY_APP_GITHUB_RELEASE_TAG = 'v1.0.0'
$env:COMMUNITY_APP_INSTALLER_ASSET = 'sohun-setup-1.0.0-1-windows-x64.exe'
$env:COMMUNITY_APP_RELEASE_NOTES = '首个公开版本'
```

数据库、备份目录、`COMMUNITY_PASSWORD_PEPPER`、`COMMUNITY_ADMIN_TOKEN` 和 SMTP 密码只放在服务器密钥管理中。生产 API 必须通过 Caddy/Nginx 提供 HTTPS，外部探针使用 `/ready`。

当前发布按产品负责人 2026-09-06 确认的策略开放注册，不要求邮箱验证码：
`COMMUNITY_REGISTRATION_ENABLED=true`、`COMMUNITY_REQUIRE_EMAIL_VERIFICATION=false`。
SMTP 暂不接入，邮箱归属未经验证，邮件找回密码不可用；不要把免验证注册当作邮箱所有权证明。
后续接入时配置 `COMMUNITY_SMTP_HOST/PORT/SECURE/USER/PASSWORD/FROM`，
再把 `COMMUNITY_REQUIRE_EMAIL_VERIFICATION` 改为 `true` 并重启服务。

打印故障历史默认每账号最多 10,000 条、50 MiB（UTF-8 JSON，预留已读与解除时间空间），
可通过 `COMMUNITY_MAX_PRINTER_FAULTS_PER_USER` 和 `COMMUNITY_MAX_PRINTER_FAULT_BYTES_PER_USER`
设置正整数配额。达到上限时拒绝新增/扩容并保留已有历史；仍允许幂等重传、已读及解除，
不自动删除故障记录。故障路由按来源 IP 每分钟最多 600 次请求，
同账号与 IP 的写入最多 120 次、后台凭据签发最多 10 次；后台读取凭据响应禁止缓存。
将来启用找回密码后，成功重置会同时撤销主会话和后台故障读取凭据。

## 2. 官网

在 `官网网页制作` 启动网站，并把官网的安装包地址配置为 GitHub Release 的真实 asset URL：

```powershell
$env:SOHUN_DOWNLOAD_URL = 'https://github.com/你的账号/你的仓库/releases/download/v1.0.0/sohun-setup-1.0.0-1-windows-x64.exe'
$env:COMMUNITY_BACKEND_ORIGIN = 'https://api.sohun.top'
npm start
```

`/download` 只接受 HTTPS、无凭据和无查询参数的地址；未配置时会返回明确的 503 页面，不会生成错误下载链接。

## 3. GitHub 上线前

1. 撤销曾经暴露的 PAT，并使用本机 Git Credential Manager 或 GitHub CLI 登录。
2. 提供 GitHub 用户名/组织名和最终仓库名，确认仓库是否公开。
3. 检查 `电脑软件/THIRD_PARTY_NOTICES.md`，确认 Bambu 相关资源和
   `assets/tools/ffmpeg/ffmpeg.exe` 具备公开再分发许可；未确认的资源不要放进公开仓库。
4. 配置仓库变量 `SOHUN_PUBLIC_RELEASE_ENABLED=true`，并把审核后的清单和签名证书写入
   `SOHUN_RELEASE_CLEARANCE_JSON`、`SOHUN_RELEASE_ASSETS_ARCHIVE_URL`、
   `SOHUN_RELEASE_ASSETS_TOKEN`、
   `SOHUN_SIGNING_CERT_PFX_BASE64`、
   `SOHUN_SIGNING_CERT_PASSWORD`、`SOHUN_SIGNING_CERT_THUMBPRINT` secrets。
5. 推送源码后创建 `v1.0.0` tag，等待 Windows Release workflow 上传签名安装包。
6. 把 Release asset URL 同步到 API 的 `COMMUNITY_APP_*` 变量和官网 `SOHUN_DOWNLOAD_URL`。

## 4. 部署后验证（只读）

运行 `scripts/check_launch_endpoints.ps1`。脚本确认 API、数据库、备份就绪及邮箱策略一致，
个人库存快照、分页事件及故障提醒接口已部署（匿名访问应返回 401，不能是 404，且禁止缓存），
更新配置包含版本与下载地址，并且官网 `/download` 可以重定向到安装包。
默认检查 `https://api.sohun.top` 与 `https://sohun.top`，不登录、不写入线上数据。
当前免邮箱验证策略接受 `email=not_required`；接入 SMTP 后用
`scripts/check_launch_endpoints.ps1 -RequireEmailVerification` 强制检查邮件服务就绪。

健康检查通过不代表服务器已经更新到当前代码。若快照/事件接口返回 404，
先部署新版 community_server 并完成迁移，再验收桌面与 Android 的双向同步；
不能把这个失败归因于客户端账号或网络设置。
