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

这些目录已在根 `.gitignore` 中阻止误提交。正式 Release 工作流会从受保护的
GitHub Secret 临时注入已审核的资源和清单；没有清单与代码签名证书时，工作流
会 fail-closed，不会生成公开安装包。

资源包通过受保护的 HTTPS 地址 `SOHUN_RELEASE_ASSETS_ARCHIVE_URL` 提供，访问令牌
放在 `SOHUN_RELEASE_ASSETS_TOKEN`。压缩包只应包含相对路径下的已审核 `assets/`
文件；工作流会拒绝绝对路径和路径跳转，且不会把资源写入 Git 历史。运行时
`.sha256` 完整性清单由工作流按注入后的二进制现场生成，不需要放进资源包。

## 发布门禁

在 Bambu 资源取得书面再分发依据、补齐对应许可证文本和来源清单前，不得把
个人版安装包或这些二进制推送到公开 GitHub Release。`build_release.ps1` 的
`Test-ReleaseClearance.ps1` 是正式分发门禁；`release-clearance.example.json`
只是失败示例，不是许可证明。

## Core 预览边界

Core 预览是单独标记的未签名预发布变体。它只能从
`scripts/export_public_source.ps1 -CoreAssets` 生成的完整文件清单快照构建；导出和成品检查会
拒绝上面列出的资源、私钥、令牌、数据库、内部运维文档以及清单外新增或被改写的文件。

Windows 便携包与安装器必须明确标注未进行 Authenticode 签名，Android APK 必须明确标注为
调试证书签名。Core 预览只允许发布到与 `pubspec.yaml` 版本一致的 `core-v<版本+构建号>` 标签，
并设置为 GitHub Prerelease。它不解除完整正式发行所需的资源许可、来源清单、实机验收或签名门禁。
