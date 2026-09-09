# 耗材工作台社区服务

自托管配置见仓库根目录 [DEPLOYMENT.md](../../DEPLOYMENT.md)。

这是软件账号和参数广场的自托管 API。它与拓竹云账号完全独立，不会接触或代管拓竹密码。

## 运行要求

- Node.js 24 或更高版本
- 生产环境由 Caddy、Nginx 或云负载均衡提供 HTTPS

## 启动

```powershell
$env:COMMUNITY_PASSWORD_PEPPER = '<至少 32 字节随机值>'
$env:COMMUNITY_ADMIN_TOKEN = '<至少 32 字节随机值，仅保存在服务器>'
$env:COMMUNITY_DATABASE_PATH = 'D:\community-data\community.sqlite'
$env:COMMUNITY_BACKUP_DIRECTORY = 'E:\community-backups'
$env:COMMUNITY_BACKUP_RETENTION_DAYS = '30'
$env:COMMUNITY_BACKUP_INTERVAL_HOURS = '24'
$env:COMMUNITY_TERMS_VERSION = '2026-07-29'
$env:COMMUNITY_PRIVACY_VERSION = '2026-07-29'
$env:COMMUNITY_SUPPORT_EMAIL = 'support@example.com'
$env:COMMUNITY_REQUIRE_EMAIL_VERIFICATION = 'true'
$env:COMMUNITY_SMTP_HOST = 'smtp.example.com'
$env:COMMUNITY_SMTP_PORT = '587'
$env:COMMUNITY_SMTP_SECURE = 'false'
$env:COMMUNITY_SMTP_USER = '<SMTP 用户名>'
$env:COMMUNITY_SMTP_PASSWORD = '<SMTP 专用密码>'
$env:COMMUNITY_SMTP_FROM = '"sohun" <no-reply@example.com>'
$env:COMMUNITY_SMTP_REPLY_TO = 'support@example.com'
$env:COMMUNITY_APP_LATEST_VERSION = 'v1.0.0'
$env:COMMUNITY_APP_GITHUB_REPOSITORY = 'OWNER/REPOSITORY'
$env:COMMUNITY_APP_GITHUB_RELEASE_TAG = 'v1.0.0'
$env:COMMUNITY_APP_INSTALLER_ASSET = 'sohun-setup-1.0.0-1-windows-x64.exe'
$env:COMMUNITY_APP_RELEASE_NOTES = '本次更新内容摘要'
$env:COMMUNITY_TRUST_PROXY = 'loopback'
$env:COMMUNITY_PUBLIC_IMAGE_HOSTS = 'api.example.com'
# 可选：仅本机演示时显式启用；密码不要写入仓库或命令行历史
# $env:COMMUNITY_LOCAL_INSPECTION_ACCOUNT = 'true'
# $env:COMMUNITY_LOCAL_INSPECTION_ACCOUNT_PASSWORD = '<本机随机密码>'
# 可选：$env:COMMUNITY_SUPPORT_CODES = '第三方卡密1,第三方卡密2'
$env:COMMUNITY_MAX_PRESETS_PER_USER = '100'
$env:COMMUNITY_MAX_PRESET_BYTES_PER_USER = '52428800'
$env:STUDIO_OPEN_STREAM_ENABLED = 'true'
$env:STUDIO_OPEN_STREAM_RTMP_BASE_URL = 'rtmp://api.sohun.top:1935/'
$env:STUDIO_OPEN_STREAM_HLS_BASE_URL = 'https://api.sohun.top/stream/'
$env:NODE_ENV = 'production'
$env:HOST = '127.0.0.1'
$env:PORT = '27861'
node src/server.js
```

当前生产环境使用自托管开源 MediaMTX：农场 Windows 客户端通过审查过的
FFmpeg/摄像头桥接向服务器的 RTMP 端口推流，MediaMTX 再以 HLS 提供网页播放。
服务端为每个正在观看的工单生成随机流路径和短时推流地址，网页隐藏或会话过期后
客户端停止 FFmpeg 与打印机摄像头连接；服务器不录像、不把视频发送到腾讯云。
桌面端需要可执行的 FFmpeg，正式安装包应放在 `{app}\tools\ffmpeg\ffmpeg.exe`；
开发时可使用 `SOHUN_FFMPEG_PATH` 指向经过许可审查的本机 FFmpeg。

若未设置 `STUDIO_OPEN_STREAM_*`，服务会退回内存 JPEG 兼容模式。腾讯云 WebRTC
仍是未来可选传输，只有完整配置 `STUDIO_TENCENT_*` 环境变量时才启用，不能与
自托管 MediaMTX 同时启用。

When `COMMUNITY_APP_DOWNLOAD_URL` is set, it takes precedence. Otherwise the
GitHub repository, release tag, and installer asset settings above generate a
HTTPS Releases URL in `/v1/config`. The desktop client reads that endpoint in
Settings > About and updates. Publishing a new installer then requires a
GitHub Release plus updating the version, tag, asset name, and release notes.
Never put a GitHub token or any server credential in this file.

Production requires `COMMUNITY_ALLOWED_ORIGIN` to be one exact HTTPS origin, for example `https://app.example.com`. Native desktop clients do not depend on browser CORS; Web deployments must use the actual Web client origin, without a path or `*`.

```powershell
$env:COMMUNITY_ALLOWED_ORIGIN = 'https://app.example.com'
```

当 Caddy/Nginx 与本服务位于同一台机器并通过回环地址转发时，可设置
`COMMUNITY_TRUST_PROXY=loopback`。反向代理必须覆盖（不能追加）
`X-Forwarded-For`，且值只能是一个客户端 IP；服务端只会在直接连接方确实是
回环 IP 时信任该头。多实例部署还需要 Redis 等共享限流器，不能依赖当前进程内桶。

远程头像和预览图默认关闭；只有 `COMMUNITY_PUBLIC_IMAGE_HOSTS` 中显式列出的
受信任 HTTPS 主机才允许写入和返回。该配置只接受逗号分隔的精确主机名，不支持
通配符、协议或端口。桌面客户端只自动加载与社区 API 同源的图片，因此建议通过
同一反向代理主机暴露媒体路径。预设数量和不可变历史版本的累计字节数分别由
`COMMUNITY_MAX_PRESETS_PER_USER` 与 `COMMUNITY_MAX_PRESET_BYTES_PER_USER` 限制。

生产模式必须显式提供数据库、独立备份目录、支持邮箱、强 pepper 和管理员令牌；启用邮箱验证时还必须提供完整 SMTP 配置。服务会先校验配置，再打开数据库。随后验证 SMTP 连接并生成一次经过 `integrity_check` 的启动备份；任一步失败都不会开始监听端口。备份目录应位于独立磁盘，并由服务器运维继续同步到异地或对象存储。

SMTP 端口 465 使用 `COMMUNITY_SMTP_SECURE=true`；587 使用 `false` 并强制 STARTTLS。验证码为 8 位数字、15 分钟有效、最多尝试 5 次，数据库只保存带服务器 pepper 的 HMAC，不保存明文验证码。

桌面客户端通过构建参数指定公开 HTTPS 地址：

```powershell
.\build_release.ps1 `
  -ApiBaseUrl https://api.example.com `
  -CertThumbprint <代码签名证书 SHA1> `
  -ThirdPartyClearanceManifest C:\secure\sohun-release-clearance.json
```

正式发布脚本要求有效代码签名证书和经过审查的第三方再分发许可清单，缺少任一项都会失败。开发或内部验证请使用 `scripts\build_windows.ps1`。

开发时也可以在软件的账号设置中填写本机地址 `http://127.0.0.1:27861`。

桌面端 Release 默认连接 `https://api.sohun.top`，也可以在构建时通过
`--dart-define=APP_API_BASE_URL=https://your-api.example` 覆盖。要启用自动更新元数据，
生产服务需要设置 `COMMUNITY_APP_LATEST_VERSION`、`COMMUNITY_APP_DOWNLOAD_URL`
（或 `COMMUNITY_APP_GITHUB_REPOSITORY`、`COMMUNITY_APP_GITHUB_RELEASE_TAG`、
`COMMUNITY_APP_INSTALLER_ASSET`）以及 `COMMUNITY_APP_RELEASE_NOTES`。

## 已实现接口

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `POST /v1/auth/refresh`
- `POST /v1/auth/logout`
- `POST /v1/auth/password-reset/request`
- `POST /v1/auth/password-reset/confirm`
- `GET/PATCH/DELETE /v1/me`
- `GET/PUT /v1/me/inventory/snapshot`（账号隔离的桌面端/手机端个人库存快照同步）
- `GET/POST /v1/me/inventory/events`（个人库存事件分页与幂等批量接收）
- `GET/PATCH /v1/me/devices/:printerKey`、`GET/POST /v1/me/devices/:printerKey/maintenance`（NTAG213 独立设备工作台）
- `GET /v1/me/devices`、`POST /v1/me/devices/status`、`GET /v1/me/device-tags/:deviceToken`（设备状态共享与标签入口）
- `GET /v1/supporters`（公开共创致谢墙）
- `POST /v1/supporters/redeem`（登录绑定或匿名登记一次性支持卡密）
- `POST /v1/admin/support-codes`（管理员导入第三方商城卡密）
- `POST /v1/me/email-verification/request`
- `POST /v1/me/email-verification/confirm`
- `GET /v1/policies/terms/:version`
- `GET /v1/policies/privacy/:version`
- `GET /v1/admin/users`（仅服务器管理员令牌，可查看注册账号；不返回密码哈希或会话令牌）
- `GET /v1/admin/metrics`
- `GET/POST /v1/admin/backups`
- `GET/POST /v1/presets`
- `GET/PATCH/DELETE /v1/presets/:id`
- `PUT/DELETE /v1/presets/:id/like`
- `POST /v1/presets/:id/download`

服务端从访问令牌确定作者，忽略参数 JSON 中可编辑的 `author`；更新必须提交 `revision`，过期版本返回 `409`，防止静默覆盖。

个人库存同步使用独立的 `personal_inventory_snapshots` 表，不复用农场工作室快照。当前源码数据库迁移为 **27**；其中
migration 27 的 `personal_stock_receipt_items` 表是 CUID/FUID 可重复资料卡的批次回执账本。客户端提交当前 `revision`、完整
`records` 快照和桌面端型号库 `materialCatalog`，服务端以账号 ID 隔离数据并原子递增版本；版本不匹配返回
`409 revision_conflict` 和 `currentRevision`。记录和型号库只接受桌面端业务字段及 CUID/FUID 来源 UID、卡型、批次回执字段，
拒绝 NTAG213、RFID 原始块、MIFARE 密钥、签名和其他凭据，不会把这些内容写入数据库。来源卡 UID 与当前上机标签绑定
分开保存；同一来源卡可在不同新操作中新增多卷，同一操作 UID 重试不会产生副本。

NTAG213 路由只处理设备标识、状态、故障关联和维护事件；它不读写耗材模板，也不调用个人库存入库、余量或换卷接口。

`PATCH /v1/me` 只接受 `handle`、`displayName`、`bio`、`avatarUrl`；用户名仍需全局唯一，冲突返回 `409 handle_exists`。密码按客户端提交的原始字符校验和哈希，不会静默去除首尾空格。

### 第三方支持商城与致谢墙

桌面端会在支持页下半部分内嵌 `https://pay.ldxp.cn/shop/Salcara`，并保留外部浏览器兜底；Windows 机器需要 WebView2 Runtime。该商城目前没有可供本服务直接调用的公开卡密校验接口，因此支付完成后需要把商城返回的卡密导入本服务；服务端只保存带 pepper 的 HMAC，不保存明文卡密。可以在启动前设置逗号分隔的 `COMMUNITY_SUPPORT_CODES`，也可以使用管理员令牌动态导入：

```powershell
$headers = @{ Authorization = "Bearer $env:COMMUNITY_ADMIN_TOKEN" }
$body = @{ codes = @(
  @{ code = '第三方返回的卡密'; tier = '同行支持' }
) } | ConvertTo-Json
Invoke-RestMethod https://api.example.com/v1/admin/support-codes `
  -Method Post -Headers $headers -ContentType 'application/json' -Body $body
```

仓库还提供了不依赖第三方包的生成/导入助手。它使用 Node.js `crypto` 生成高熵、易人工抄写的卡密；生成出来的卡密只适用于你自己发行的支持商品，不能替代第三方商城已经发出的卡密。第三方商城卡密可以整理成 JSON 数组、`{"codes": [...]}` 或“一行一个卡密”的文本后批量导入：

当前商城支持四个金额档位，卡密中的 `tier` 建议统一使用以下标签：

| 金额 | tier 标签 | 命令行简写 |
| ---: | --- | --- |
| 10 元 | `10元支持` | `10` |
| 20 元 | `20元支持` | `20` |
| 50 元 | `50元支持` | `50` |
| 100 元 | `100元支持` | `100` |

`generate` 和 `import` 都会把数字简写自动规范为上面的标签；导入旧卡或第三方自定义卡时仍可保留自定义 `tier`。

```powershell
# 生成 100 枚 10 元自有卡密；明文只写入本机文件，请妥善保管并用于发货
node scripts/support_codes.mjs generate `
  --count 100 --tier 10 --out .\support-codes-10.json

# 其他档位分别使用 --tier 20、--tier 50 或 --tier 100

# 使用服务器管理员令牌导入；令牌从环境变量读取，不写入命令行历史
$env:COMMUNITY_ADMIN_TOKEN = '<服务器管理员令牌>'
node scripts/support_codes.mjs import `
  --file .\support-codes-10.json `
  --base-url https://api.example.com
```

管理员令牌只通过 HTTPS 发送，服务端接收后立即计算 HMAC，数据库不保存卡密明文。导入结果中的 `inserted` 是新卡数量；重复导入不会重复创建。生成文件和第三方商城导出的卡密清单都属于敏感资料，发放完成后应从工作电脑安全删除。

用户输入卡密时可以登录并绑定自己的头像、昵称和留言，也可以选择匿名加入；留言最多 30 个字符，每枚卡密只能登记一次。

注册时客户端会把邮箱、唯一用户名、显示名称、密码以及用户确认的条款/隐私版本发送到本服务。数据库只保存 scrypt 密码哈希和条款确认时间，不保存密码明文；会话令牌也只保存 SHA-256 哈希。可用管理员令牌读取账号目录：

```powershell
$headers = @{ Authorization = "Bearer $env:COMMUNITY_ADMIN_TOKEN" }
Invoke-RestMethod https://api.example.com/v1/admin/users -Headers $headers
```

也可以使用仓库内的只读助手自动翻页并仅输出安全字段：

```powershell
$env:COMMUNITY_PUBLIC_BASE_URL = 'https://api.example.com'
.\scripts\list_registered_users.ps1 -Status active -PageSize 100
```

管理员令牌只能保存在服务器或管理员自己的安全环境中，绝不能编译进客户端，也不能复用为客户运营台身份。

## 备份、恢复与监控

服务启动时和每个配置周期自动执行 SQLite 在线备份。备份完成后会重新以只读方式打开并执行 `PRAGMA integrity_check`，记录大小、SHA-256、schema 版本和结果；过期备份自动清理。

```powershell
# 单次健康检查；适合任务计划程序、Uptime Kuma、Zabbix 等外部监控调用
$env:COMMUNITY_PUBLIC_BASE_URL = 'https://api.example.com'
.\scripts\monitor_community_server.ps1

# 单独验证一个备份
node .\scripts\verify_backup.mjs 'E:\community-backups\sohun-community-....sqlite'

# 停止 Node 服务后恢复；已有数据库必须显式允许替换，并会保留安全副本
.\scripts\restore_database.ps1 `
  -BackupPath 'E:\community-backups\sohun-community-....sqlite' `
  -DatabasePath 'D:\community-data\community.sqlite' `
  -ReplaceExisting
```

`GET /health` 只表示进程存活；`GET /ready` 以数据库和备份新鲜度决定是否可接流量，并把运行期邮件故障标记为 `degraded`，避免单次邮件失败拖垮全部登录与社区功能。外部负载均衡应以 `/ready` 作为就绪探针。管理员指标不包含邮箱、路径、令牌或密码数据。

## 条款与隐私政策

当前正文位于 `policies/terms/2026-07-29.md` 与 `policies/privacy/2026-07-29.md`。修改实质内容时必须新增日期版本文件，同时更新服务端和客户端的版本常量；禁止覆盖已经被用户同意的历史版本。客户端注册前会从当前账号服务器读取并展示两份正文，用户分别阅读后才能勾选同意。

## 上线前

SQLite 适合单机和早期商用部署。多实例或高并发时应迁移 PostgreSQL、共享限流器和集中任务队列，并进一步建设对象存储、内容审核后台、异地备份告警和邮件退信处理。不要直接把此 HTTP 端口暴露到公网，必须通过 HTTPS 反向代理。
