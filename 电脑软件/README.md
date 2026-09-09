# sohun 耗材工作台

Windows 桌面端 3D 打印耗材库存、打印任务、设备状态与参数效果管理工具。客户端以 Flutter + Riverpod + Drift 构建。

拓竹打印机的连接严格分为两条独立链路：云端模式使用拓竹账号的云 MQTT 和 TUTK/P2P 摄像头；局域网模式使用打印机 IP、LAN Access Code 和本地 TLS/MQTT/摄像头协议。应用只使用用户明确选择的模式，云端失败不会自动改走 LAN，云端摄像头也不会执行局域网发现。

## 工程组成

| 目录 | 作用 | 数据边界 |
|---|---|---|
| `lib/` | 主桌面客户端 | 本地 Drift 数据库、受保护的账号与打印机连接配置 |
| `community_server/` | Node.js 社区服务 | 独立 SQLite、账号、会话、参数广场和邮件验证 |
| `assets/` | 品牌、打印机和本地校准资源 | Bambu Studio 预设、图标和原生集成资源按许可状态单独注入 |
| `android/` + `lib/main_mobile.dart` | 原生 Android RFID 扩展 | 复用桌面 Drift 库、型号库、颜色面板和 sohun 账号 |

主客户端按 `core`、`data`、`providers`、`features`、`widgets` 分层。数据库结构以 `AppDatabase.schemaVersion` 为唯一 SQLite 结构版本；`MigrationManager` 只记录 Drift 成功打开的版本，不再创建表或列。`test/database_all_versions_migration_test.dart` 会从 v1 到当前版本逐版生成快照，再验证每个版本均可升级且数据完整。

## 开发环境

- Windows 10/11 x64
- Flutter 3.44.4 / Dart 3.12 或兼容版本
- Visual Studio 2022，安装“使用 C++ 的桌面开发”
- Node.js 24 或更高版本（仅社区服务）
- PowerShell 5.1 或更高版本

```powershell
flutter pub get
dart analyze lib test
flutter test --no-pub
```

### Android 移动扩展

Android 使用同一个 Flutter 工程，不使用早期 `手机软件/` 浏览器原型。入口是
`lib/main_mobile.dart`，Gradle 已将 Android 目标固定到该入口：

```powershell
flutter run -t lib/main_mobile.dart
.\scripts\build_android.ps1 -Configuration Debug
```

`build_android.ps1` 会在中文工程路径下自动使用 ASCII 暂存目录，完成后把
`app-debug.apk` 复制回 `build/app/outputs/flutter-apk/`。

主写入页右上角「复用耗材模板」会按当前账号加载成功写入历史和已同步库存中的
品牌、型号与颜色，相同内容自动合并；选择后回填表单，便于连续处理 CUID/FUID 操作。
完整 AMS 模板只写入已确认的 CUID/FUID 目标卡；模板写入并回读成功后登记当前实物卷。
模板不会复制到其他库存行，也不会把同一 UID 当成多卷的唯一身份。

库存页另有「读取 CUID/FUID」批量入库入口：读取同一张可重复资料卡后，用户明确选择
1–100 卷并确认；每卷生成独立库存 UID，并保留来源卡 UID、卡型、批次操作 UID 与序号。
点取消、关闭弹窗或从桌面待办移除均不增加库存；同一批次重试幂等，下一次到货使用新的
操作 UID 即可再次使用同一张卡。按余量入库可登记一卷实际余量，已消耗卷不会被重复读取补满。
NTAG213 只用于独立的设备工作台（定位打印机、查看状态/故障、记录维护），不写耗材资料、
不进入库存/模板/余量接口。NFC 只在明确的读写、扫描或设备状态操作时检测；网络失败保留
本机记录并提示待同步。Android Debug 包用于侧载测试，正式 Release 需自行配置发布签名
（`android/key.properties`），不会回退使用调试签名发布。

当前客户端数据库 schema 为 56，个人库存 API 需服务端 migration 27。登录 sohun 后，
库存与桌面端型号库通过 `GET/PUT /v1/me/inventory/snapshot` 及批次事件接口合并；未登录时
先写本机 SQLite，登录后自动补传。源码不包含 Bambu 密钥、扇区 dump、签名或未经授权的
标签克隆逻辑；读写回读通过不等于 AMS 官方兼容，真实硬件仍需逐台验证。

社区服务：

```powershell
Set-Location community_server
npm ci
npm test
npm audit --omit=dev --registry=https://registry.npmjs.org
```

个人版公开仓库不包含内部运营台。在工作区根目录运行 `scripts/verify_all.ps1`
可检查个人版客户端、社区服务、官网和手机端演示构建；加 `-IncludeBuild` 会构建个人版 Windows 客户端。

公开源码中的 `assets/bambu_presets/`、`assets/images/bambu_icons/` 和 `assets/bin/`
只保留占位目录。Bambu 相关资源在取得再分发许可后，通过受保护的发布资源包注入，
未注入时核心库存、任务和本地管理功能仍可开发与测试。

农场客户的云端摄像头链路还需要本机安装受支持版本的 Bambu Studio（用于提供
`BambuSource.dll` 及其官方插件依赖），以及安装包内的
`tools\ffmpeg\ffmpeg.exe`。桥接程序和 `bambu_networking.dll` 使用 Visual C++
运行库；如果目标机器没有对应的 VC++ Redistributable，需先安装受支持版本，或由
发布方在安装器中按许可随包部署。局域网摄像头和个人版库存功能不依赖这些农场组件。

## Windows 构建

项目所在路径含中文时，不要直接执行 `flutter build windows`。辅助脚本会复制到纯 ASCII 暂存目录，排除 Flutter 临时符号链接，再将产物复制回来：

```powershell
.\scripts\build_windows.ps1 -Configuration Release
.\scripts\build_windows.ps1 -Configuration Release -NoClean
```

内部安装包可在 Release 构建后使用 Inno Setup 6.7 或更高版本生成。安装器使用
亮绿色默认图标和每用户安装目录。个人版使用约 480 × 360 的浅色圆角窗口，
安装位置、桌面快捷方式和说明确认集中在一页，安装中显示真实进度，完成后可选择打开或稍后打开：

```powershell
.\scripts\build_installer.ps1
```

只查看个人版安装过程的 UI，无需构建 Flutter 客户端：

```powershell
.\scripts\preview_installer.ps1 -Page Progress
```

`-Page Setup` 和 `-Page Finished` 可分别查看设置页和完成页。预览文件位于
`dist\installer\sohun-install-<page>-preview.exe`，不包含应用文件，安装写入入口也被阻止。

该命令生成 `dist\installer\sohun-setup-<version>-windows-x64.exe`。对外分发前仍须
完成下述许可清理与代码签名门禁，安装器本身也必须签名。

上述命令用于开发和内部验证，产物可以未签名。正式对外发布必须使用失败关闭的发布脚本：

```powershell
.\build_release.ps1 `
  -ApiBaseUrl https://api.example.com `
  -CertThumbprint <代码签名证书 SHA1> `
  -ThirdPartyClearanceManifest C:\secure\sohun-release-clearance.json
```

正式脚本要求 HTTPS API、已安装且有效的代码签名证书，以及经审查的第三方再分发许可清单；缺少任一项都会在生成分发包前失败。`release-clearance.example.json` 只是拒绝发布的结构示例，不代表已经取得许可。许可范围和受影响资产见 `THIRD_PARTY_NOTICES.md`。

## 安全边界

- LAN Access Code 不通过进程命令行传给原生绑定工具；工具从 stdin 读取。
- LAN MQTT 首次连接前显示证书 SHA-256 指纹并要求确认；信任绑定到打印机序列号和主机。证书变化会拒绝连接，删除或更换主机会清理旧信任。
- FTPS 只在实际证书与已确认的 MQTT 证书一致时共享信任，验证完成前不发送 Access Code。
- 社区头像和预览图只加载公共 HTTPS 地址；服务端和客户端都拒绝本机、私网、链路本地、凭据 URL 和畸形 URL。
- 正式发行包必须通过签名、文件哈希、API 地址和第三方许可门禁，清单随包生成。

不要把社区管理员令牌、SMTP 密码、代码签名私钥、拓竹账号或真实许可文件提交到源码目录。

## 外部服务

社区服务生产配置、反向代理、SMTP、备份与监控见 `community_server/README.md`；公开仓库
不包含服务器 SSH、卡密导入和内部运维 runbook。桌面端
开发构建默认连接本机 `http://127.0.0.1:27861`，Release 构建默认连接
`https://api.sohun.top`。Android 移动入口 `lib/main_mobile.dart` 无论是 Debug
还是 Release 都默认连接 `https://api.sohun.top`（手机上的 `127.0.0.1` 是手机自身），
测试或自托管环境可在构建时通过 `--dart-define=APP_API_BASE_URL=https://...`
覆盖。正式分发仍应在构建时显式传入已验收的公共 HTTPS API，并在服务器配置
`COMMUNITY_APP_LATEST_VERSION`、`COMMUNITY_APP_DOWNLOAD_URL` 和
`COMMUNITY_APP_RELEASE_NOTES` 以启用远程更新提示。

自动化测试不等于真实第三方兼容性验证。发布前仍需使用授权的测试账号和实体打印机完成拓竹云登录、MQTT、FTPS、绑定、SMTP、QQ OAuth 和远程模型的验收，并记录测试固件、账号区域与服务版本。

## 持续集成

工作区根目录的 `.github/workflows/ci.yml` 会执行：

- 个人版客户端静态分析和全部测试；
- 社区服务测试和生产依赖审计；
- 官网单测和 JavaScript 语法检查；
- v1 到当前版本的数据库迁移回归测试（包含在主客户端测试中）。
- Android 原生移动入口构建；历史浏览器原型单独构建。

桌面和 Android 的共享 Dart 分析、Flutter 测试只执行一次。
局部验证、全仓验收和构建诊断命令见 [开发工作流](../docs/development-workflow.md)。

根仓库已准备好，但尚未配置 GitHub remote；推送前请先确认仓库归属、公开范围
和第三方资源许可。
