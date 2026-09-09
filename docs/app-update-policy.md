# 桌面与 Android 更新配置

个人版桌面和原生 Android 通过社区 API `GET /v1/config` 读取发行配置，使用各自的版本、说明和下载地址。Android 查询带 `platform=android`，Windows 查询带 `platform=windows`；API 只返回请求平台的更新字段。已有功能开关和 ETag 缓存协议继续使用。

## 配置字段

| 远程字段后缀 | 桌面环境变量 | Android 环境变量 | 含义 |
| --- | --- | --- | --- |
| `latest_version` | `COMMUNITY_APP_LATEST_VERSION` | `COMMUNITY_ANDROID_LATEST_VERSION` | 最新版本，如 `v1.2.0+3`，必填 |
| `min_supported_version` | `COMMUNITY_APP_MIN_SUPPORTED_VERSION` | `COMMUNITY_ANDROID_MIN_SUPPORTED_VERSION` | 最低支持版本；空字符串表示不设置最低门槛 |
| `force_update` | `COMMUNITY_APP_FORCE_UPDATE` | `COMMUNITY_ANDROID_FORCE_UPDATE` | `true` 强制所有较旧版本升级，`false` 根据最低版本判定 |
| `release_notes` | `COMMUNITY_APP_RELEASE_NOTES` | `COMMUNITY_ANDROID_RELEASE_NOTES` | 更新说明，支持多行纯文本 |
| `download_url` | `COMMUNITY_APP_DOWNLOAD_URL` | `COMMUNITY_ANDROID_DOWNLOAD_URL` | 对应平台的 HTTPS 下载页或安装包地址 |

远程字段分别以 `desktop_`、`android_` 开头，例如 `android_force_update`。环境变量接受 `true`/`false`（也兼容 `1`/`0`）；远程 JSON 必须使用布尔类型，不能使用字符串。

桌面兼容现有 `COMMUNITY_APP_*` 命名；Android 不会回退到桌面版本或 Windows 安装器。若使用 GitHub Releases，可分别配置 `COMMUNITY_APP_GITHUB_REPOSITORY`、`COMMUNITY_APP_GITHUB_RELEASE_TAG`、`COMMUNITY_APP_INSTALLER_ASSET` 与对应 `COMMUNITY_ANDROID_*` 三项。显式 `DOWNLOAD_URL` 优先；配置不合法时不会悄悄打开另一个目的地。

## 可选与强制更新

版本按主版本、次版本、修订号、构建号依次比较，例如 `1.0.0+12` 高于 `1.0.0+2`。缺少构建号视为 `0`。客户端使用与 `pubspec.yaml` 一致的 `AppVersion.fullVersion`；服务端版本格式为三个整数段及可选 `+整数`，不接受预发行字符串。

- 最新版本高于当前版本，且 `force_update=false`、当前版本不低于最低支持版本：可选更新，可以稍后处理。
- 最新版本高于当前版本，且 `force_update=true` 或当前版本低于最低支持版本：强制更新，需要更新后继续使用。
- 当前版本已经达到最新版本：不产生更新循环，即使旧配置仍有 `force_update=true`。
- 最低支持版本高于最新版本、版本格式不合法、字段类型错误：配置无效，不作为“已是最新版”或“解除强制”的依据。

正式启用强制更新时必须同时配置实际可访问的 HTTPS 下载目的地。客户端拒绝 HTTP、带用户名密码和本地文件地址。若目的地缺失或打开失败，界面保留更新要求并允许重新检查，不会把浏览器打开成功当作下载安装完成。

下面是两端独立配置的示例。值仅用于说明，不指向实际发布包：

```json
{
  "desktop_latest_version": "v1.2.0+3",
  "desktop_min_supported_version": "v1.1.0+1",
  "desktop_force_update": false,
  "desktop_release_notes": "修复库存展示\n改善交互反馈",
  "desktop_download_url": "https://downloads.example.com/sohun-windows.exe",
  "android_latest_version": "v1.0.0+4",
  "android_min_supported_version": "v1.0.0+3",
  "android_force_update": true,
  "android_release_notes": "修复写卡问题",
  "android_download_url": "https://downloads.example.com/sohun-android.apk"
}
```

## 重试、缓存与撤回

用户可从桌面“设置 → 关于与更新 → 软件更新”或手机“我的 → 软件更新”手动检查。两端共用玻璃更新面板：显示当前版本、新版本、真实更新说明及浏览器移交状态；长说明、小屏和大字号可滚动，入场动画遵循“减少动画”偏好。

可选更新支持“稍后提醒”和“跳过此版本”。跳过偏好按设备平台保存，手动更新中心仍可查看该版本。“新版本提醒”开关只控制可选更新的自动提示，不关闭必要版本检查。自动提示等待启动介绍和已打开的页面结束，避免叠加弹窗。

强制更新层位于业务导航之上，隔离背后点击、键盘焦点和读屏内容；返回、Esc、打开下载页或新增登录路由不会解除它。底层页面和未提交表单保持挂载，手机登记页暂停尚未完成的 NFC 等待，已确认的库存保存继续按原流程完成。

启动、恢复前台、定时刷新和手动检查共用配置服务，并发检查合并。网络失败保留上次已确认的版本、说明和下载入口；已确认的强制策略会从本地缓存恢复，包括过期缓存。应用内门禁还会跨更新服务重建保留要求，避免切换服务地址时出现短暂放行。

同一版本的下载地址临时缺失或无效时，保留并缓存上次有效的 HTTPS 地址，重启后仍可使用；新版本不会复用旧版本安装包地址。

撤回强制策略需下发同级或更新的 `latest_version`、明确的 `force_update=false`，并且明确设置 `min_supported_version` 为空字符串或不高于当前版本。缺失字段、空响应、较低的最新版本和异常配置不会解除已确认的要求，也不会抹掉原有缓存。有效撤回后，仍有新版本时转为可选更新。

更新按钮只将用户交给浏览器和系统安装流程，不在客户端内自动下载、执行安装包或伪造下载进度。现有数据完整性、库存结算等不可变安全功能不受更新配置开关控制。

## 验证与发布

相关验证文件为 `电脑软件/test/app_update_service_test.dart`、`电脑软件/test/remote_config_service_test.dart`、`电脑软件/community_server/test/release_metadata.test.js`，以及更新对话框和根门禁 UI 测试。命令遵循[开发工作流](development-workflow.md)，Flutter 测试使用 `--concurrency=2`。

本次实现和本地验证不会修改线上环境变量、上传安装包或部署服务。实际版本发布继续遵循[发布边界](../PUBLIC_RELEASE_MANIFEST.md)。
