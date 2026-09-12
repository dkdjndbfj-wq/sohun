# 公开仓库发布边界

## 计划公开

- `电脑软件/lib`、`电脑软件/test`、`电脑软件/windows`、`电脑软件/scripts`
  以及 Flutter 配置文件。
- 客户端 `docs` 中含服务器、SSH、内部设计或运维信息的文档不公开；公开审计
  文档统一放在根目录 `docs/`。
- `电脑软件/community_server` 社区 API、政策正文和测试。
- `官网网页制作` 官网服务器、页面模板、静态资源和测试。
- `.github/workflows`、根目录 `README.md`、`LICENSE`、`DEPLOYMENT.md`。

## 不公开

- 本机日志、调试截图、逆向分析脚本、临时构建目录和重复源码压缩包。
- 数据库、备份、账号令牌、SMTP 密码、代码签名私钥和任何 `.env` 文件。
- `电脑软件/assets/bambu_presets`、`assets/images/bambu_icons`、`assets/bin`、
  `assets/tools`、`assets/knowledge` 和 `assets/calibration` 中的 Bambu 资源、相关二进制、
  导入的离线故障文案与预置校准模型：当前
  [`电脑软件/THIRD_PARTY_NOTICES.md`](电脑软件/THIRD_PARTY_NOTICES.md) 标记为未完成再分发许可审查。

这些目录已在根 `.gitignore` 中阻止误提交。完整厂商集成 Release 工作流会从受保护的
GitHub Secret 临时注入已审核的资源和清单；没有清单与代码签名证书时，工作流
会 fail-closed，不会生成公开安装包。

资源包通过受保护的 HTTPS 地址 `SOHUN_RELEASE_ASSETS_ARCHIVE_URL` 提供，访问令牌
放在 `SOHUN_RELEASE_ASSETS_TOKEN`。压缩包只应包含相对路径下的已审核 `assets/`
文件；工作流会拒绝绝对路径和路径跳转，且不会把资源写入 Git 历史。运行时
`.sha256` 完整性清单由工作流按注入后的二进制现场生成，不需要放进资源包。

## 发布门禁

在 Bambu 资源取得书面再分发依据、补齐对应许可证文本和来源清单前，不得把
包含这些资源的安装包或这些二进制推送到公开 GitHub Release。`build_release.ps1` 的
`Test-ReleaseClearance.ps1` 是完整厂商集成版本的分发门禁；`release-clearance.example.json`
只是失败示例，不是许可证明。

完整厂商集成工作流保留为手动入口，不再截获正式公开核心版的版本标签。
公开核心版使用单独的 `Public Release` 工作流。

## 首个正式公开版本

`1.0.1+2` 按项目所有者的发布决定作为首个正式公开版本。使用
`scripts/export_public_source.ps1 -CoreAssets` 导出完整安全清单，
在 `scripts/public_core_build.ps1` 中加 `-PublicRelease` 构建。
它只包含可公开分发的核心功能，继续拒绝上述未审查资源及任何私密数据。

- 正式标签为 `v<版本+构建号>`，版本必须匹配 `pubspec.yaml`，GitHub Release 不设置为 Prerelease。
- Windows 使用 Release 编译；没有 Authenticode 证书时明确标注未签名，不伪称已认证发布者。
- Android 必须使用稳定发行密钥构建 Release APK，验证签名及证书指纹，禁止用调试 APK 冒充正式包。
- 签名私钥、口令和 `key.properties` 只允许在私有目录或 GitHub Secrets 中保存，临时注入构建目录并清理，绝不进入源码导出和发布附件。
- 源码完整清单、隐私、资源边界和成品校验继续执行；正式发布不替代真实 NFC/AMS 兼容性验收。

## 历史 Core 预览边界

Core 预览是单独标记的未签名预发布变体。它只能从
`scripts/export_public_source.ps1 -CoreAssets` 生成的完整文件清单快照构建；导出和成品检查会
拒绝上面列出的资源、私钥、令牌、数据库、内部运维文档以及清单外新增或被改写的文件。

Windows 便携包与安装器必须明确标注未进行 Authenticode 签名，Android APK 必须明确标注为
调试证书签名。Core 预览只允许发布到与 `pubspec.yaml` 版本一致的 `core-v<版本+构建号>` 标签，
并设置为 GitHub Prerelease。它不解除完整正式发行所需的资源许可、来源清单、实机验收或签名门禁。
