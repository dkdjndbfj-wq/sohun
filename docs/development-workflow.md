# 开发与验证工作流

先确定受影响的入口、共享逻辑和验收行为，再选择下面相应的命令。小改动不需要完整实施计划；复杂任务可用简短计划记录进度、决定和剩余验证。

## 按变更选择检查

命令示例使用 PowerShell。Flutter 依赖在客户端目录用 `flutter pub get` 准备，Node 项目使用 `npm ci`；已有依赖且锁文件未变化时可直接运行测试。

| 变更范围 | 工作目录 | 检查入口 |
| --- | --- | --- |
| Markdown、技能说明 | 仓库根目录 | 核对引用、命令和技能 frontmatter；无需编译产品 |
| Dart 逻辑、UI | `电脑软件` | `../scripts/analyze_dart.ps1`；`flutter test --no-pub --concurrency=2 test/<相关文件>_test.dart` |
| 社区 API | `电脑软件/community_server` | `node --test test/<相关文件>.test.js`；扩大回归用 `npm test` |
| 官网 | `官网网页制作` | `npm test`；`node --check src/server.js`；`node --check src/public_site.js` |
| Android 入口、NFC、插件 | `电脑软件` | 相关 Flutter 测试；`./scripts/build_android.ps1 -Configuration Debug`；涉及硬件的功能记录真机验收 |
| Windows 原生与打包 | `电脑软件` | `./scripts/test_windows_runtime_bundle.ps1`；`./scripts/build_windows.ps1 -Configuration Release` |
| 历史浏览器原型 | `手机软件` | `npm run build` |
| 验证脚本、CI | 仓库根目录 | `./scripts/tests/test_validation.ps1`；PowerShell/YAML 语法检查；有 actionlint 时校验工作流 |

`analyze_dart.ps1` 统一处理分析结果：error、warning 和工具异常失败，info 可通过。它不退出调用它的脚本。

## 子系统与全仓验收

在仓库根目录运行：

```powershell
./scripts/verify_all.ps1 -Scope Client -SkipInstall
./scripts/verify_all.ps1 -Scope Server,Website
./scripts/verify_all.ps1 -Scope Inventory -SkipInstall
./scripts/verify_all.ps1
./scripts/verify_all.ps1 -IncludeBuild
```

`Scope` 可选 `Client`、`Server`、`Website`、`Prototype`、`Inventory`、`All`，默认 `All`。多个范围只准备一次共享依赖。`-SkipInstall` 跳过验证脚本的依赖安装；依赖缺失或锁文件变化时不要使用它。原生构建助手仍自行管理其构建依赖。

`Inventory` 从 `电脑软件` 运行 `test/integration` 下全部专项（库存快照、入库回执、设备工作台），开启 `RUN_INVENTORY_HTTP_TESTS=true`，使用 Node.js 24 和本地社区服务依赖。与 `Client` 一起运行时并入同一次 Flutter 测试，不再单独重跑。

`-IncludeBuild` 适用于 `Client` 或 `All`，额外构建 Android Debug 与 Windows Release 各一次。只有验证增量构建或缓存修复时，再显式运行 Windows 脚本的 `-NoClean` 模式。

## 专项入口（需要时读取）

- AMS、外挂进料、型号能力：[兼容性说明](bambu-feed-compatibility.md) 与 `scripts/verify_bambu_feed.ps1`。复核官方型号变更时加 `-CheckOfficialCatalog`。
- 打印机故障库：[故障说明](bambu-printer-fault-alerts.md) 与 `scripts/verify_bambu_faults.ps1`。更新故障数据时复核官方版本。
- Windows 路径、视频缓存：[构建修复说明](windows-build-repair-2026-09-06.md)；CMake 缓存专项为 `cmake -P 电脑软件/scripts/test_media_kit_cache.cmake`。
- 发布与线上验收：[发布边界](../PUBLIC_RELEASE_MANIFEST.md)、[部署清单](../DEPLOYMENT.md)。构建请求本身不包含上传 Release、部署服务或使用真实账号修改库存。

## CI 与发布

CI 保持五个作业：主客户端执行共享 Dart 分析、Flutter 测试及本地 HTTP 集成；Android 作业构建原生移动入口；服务端、官网和历史原型各自验证。Android 作业不重复共享测试。

新提交会取消同一工作流、同一 ref 上的旧 CI。Release 按 tag 隔离并发且不取消正在执行的发布，仍要求资源许可、签名凭据、版本与 tag 一致。超时限制用于让异常作业及时失败。具体触发条件和命令以 [CI](../.github/workflows/ci.yml) 与 [Release](../.github/workflows/release.yml) 为准。

## 维护代理指引

稳定的项目约定放在根 `AGENTS.md`；按任务触发的流程放在 `.agents/skills/<name>/SKILL.md`；长命令说明保留在此文档。技能入口使用大写 `SKILL.md` 和 `name`、`description` frontmatter，避免维护另一份根目录 `skill.md`。

模型与推理强度由当前 Codex 会话设置。仓库文档提供上下文和工作约定，不会切换模型或提高算力；按代表性任务的质量、耗时、重复操作和中途停顿评估效果。规范依据与本次审计见 [Astra 审计记录](agent-workflow-audit-2026-09-06.md)。
