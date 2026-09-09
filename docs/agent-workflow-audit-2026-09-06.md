# GPT-6 Astra 代理指引与工作流审计

核对日期：2026-09-06。范围为当前仓库的代理入口、技能、历史执行指令、本地验证脚本和两个 GitHub Actions 工作流。

## 官方依据

本次直接检索并打开了 GPT-6 Astra 官方指导。其提示重点包括持续完成任务、澄清授权与技能优先级、按需委派、简洁沟通及适度验证；据此调整本仓库执行约定。[GPT-6 Astra 模型指导](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)

项目约定采用根 `AGENTS.md`，技能采用 `.agents/skills/<name>/SKILL.md`，通过简短描述触发并按需读取正文与参考资料。[AGENTS.md 发现规则](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、[技能规范](https://learn.chatgpt.com/docs/build-skills)

工作流文档按目标和必要上下文组织，避免要求每次任务都遵循固定步骤。[官方提示指导](https://learn.chatgpt.com/docs/prompting)

CI 的并发取消机制依据 GitHub 官方定义，Release 保持不取消运行中的作业。[GitHub Actions 并发](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency)

以下路径、命令和取舍来自本仓库实际代码审计；它们是项目决策，不是官方对所有项目的统一要求。

## 发现与处理

| 原状 | 已实施的调整 |
| --- | --- |
| 活跃源码范围内没有 AGENTS.md、AGENTS.override.md 或 SKILL.md | 新增一个简短根指引、一个可发现的验证技能；不额外创建根 skill.md 副本 |
| 历史 UI 计划强制调用未安装的 Superpowers 子技能，并要求先选择执行模式 | 明确历史参考地位，移除这两处强制执行指令，保留设计与验收背景 |
| 验证命令分散，开发者易误用全仓验收 | 新建开发工作流，区分局部检查、子系统回归、原生构建与发布 |
| Dart 分析门禁复制了四份：CI 两份、Release 一份、本地脚本一份 | 收敛为 `scripts/analyze_dart.ps1` 一个实现 |
| 旧门禁允许部分没有诊断信息的非零退出码通过 | 非零退出码必须有明确的 info-only 兼容依据；warning、error 和工具异常保持失败 |
| CI 的两个 Windows 作业重复分析同一份 lib/test，并重复运行 Flutter 测试 | 共享分析与测试由 main-client 执行一次；android-client 保留原生 APK 构建 |
| 本地脚本只能全仓执行，每次重装所有依赖；Flutter 测试启动两次 | 增加 Scope 与 SkipInstall；按范围发现项目、准备依赖，Client 与 Inventory 合并到一次测试调用 |
| IncludeBuild 总会连续构建 Windows Release 两次 | 默认各平台构建一次；增量构建只在相关验收时显式运行 |
| 工作流没有显式超时和旧 CI 取消机制 | 为五个 CI 作业和 Release 设置超时；同 ref 旧 CI 自动取消，发布作业不被新运行中断 |

保留了 Node 依赖审计、官方 Bambu 型号复核、历史数据库迁移测试的并发限制、真实本地 HTTP 集成、Android 编译，以及第三方资源许可与签名门禁。

`.arts`、`.codeartsdoer` 未发现有效项目技能正文；全局 AGENTS.md 为空。`public_release` 中的复制工作流、构建缓存和内部项目按其归档或忽略用途保留。用户级插件、模型设置和凭据未修改。

## 验证记录

- `scripts/tests/test_validation.ps1`：20 项行为检查通过，分别验证于 PowerShell 7 和 Windows PowerShell 5.1。覆盖分析退出码、混合诊断与异常输出、工作目录恢复、范围隔离、共享依赖去重、失败后停止及构建次数。
- 新技能通过官方 skill-creator 的 `quick_validate.py`。本机 Python 默认 GBK，验证时使用 `python -X utf8` 读取 UTF-8 技能。
- 三个新增或修改的 PowerShell 脚本通过语法解析；两个工作流通过 actionlint 1.7.12。校验工具仅下载到临时目录，下载包核对了上游 SHA-256。
- 实际执行 `scripts/verify_all.ps1 -Scope Website -SkipInstall`：官网 6 项测试和两个 JavaScript 语法检查通过。
- 实际调用统一 Dart 分析门禁：0 个 error、1 个 warning、172 个 info；门禁按设计返回失败。warning 为 `电脑软件/lib/providers/spool_change_provider.dart:5` 的未使用导入，该业务文件未在本次修改。

本次未执行全量 Flutter 测试、Windows/Android 产品构建、硬件验收或远程 GitHub Actions，也未提交、推送或发布。当前仓库没有 HEAD 提交，已有文件均处于未跟踪状态；审计前为所修改的既有文件保存了临时快照，以区分本次变更。

## 效果与后续复核

已消除的重复可直接从工作流计数确认：CI 共享分析和 Flutter 测试各由两次变为一次，本地 All 的 Flutter 测试调用由两次变为一次，IncludeBuild 的 Windows 编译由两次变为一次。模型层面的提速尚未进行 A/B 测量。

使用代表性任务观察新指引：文档修订应只校验内容与引用；单个 Dart 修复应选择相关测试；跨端库存修改应包含本地 HTTP 集成；Android NFC 改动应包含原生构建与真机验收状态。记录任务质量、总耗时、不必要的确认和重复工具调用，出现实际问题时再修订相应规则。

模型仍由 Codex 会话选择 GPT-6 Astra；AGENTS.md 和 SKILL.md 不会改变模型或推理强度。保持现有有效设置作为基线，再根据任务结果调整，避免把固定最高推理档位写成仓库规则。
