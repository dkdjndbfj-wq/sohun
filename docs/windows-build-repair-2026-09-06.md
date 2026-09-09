# Windows 构建与进料回归修复

## 进料与换卷

在当前工作区重新运行原失败用例所在的完整测试文件，连同 RFID 和引导测试，共 47 项通过。另运行进料能力、增量 MQTT、换卷弹窗、设备配置 UI 测试，22 项通过，共 69 项。

原 X1C 测试已更新为 `X1C preserves the switchable external path without counting an extra color`：保留物理外挂入口，接 AMS 后需要切换供料路径，不将其计为额外可同时打印的颜色。两个外挂换卷用例也通过。补充的协议用例确认 AMS 传感器不会误解绑外挂耗材，缺少传感器观测时不会虚构空料状态。

日志位于：

- `电脑软件/build/fix-printer-onboarding-tests.log`
- `电脑软件/build/fix-feed-ui-tests.log`

Release 检查又发现 RFID 历史窗口漏传了新查询接口必填的 `ownerAccount`。已读取该卷的实际归属账号后传入查询，并补充 UI 回归：同一个库存 UID 下，只显示该卷归属账号的同步事件，不显示另一账号的事件。最终 9 个相关测试文件合计 **71 项全部通过**，完整日志为 `电脑软件/build/fix-final-regression.log`。

## 视频依赖构建修复

原失败的 mpv 压缩包为 0 字节，GitHub 请求发生连接重置。本机共享缓存中的两个压缩包与插件固定的 MD5 一致。

新增 `电脑软件/windows/cmake/prepare_media_kit.cmake`，在加载生成的插件构建规则前执行：

- 从已安装的插件 CMake 文件读取名称、URL 和校验值，避免维护另一份版本常量。
- 校验构建目录和共享缓存，只复制通过校验的压缩包，替换构建目录里的空文件。
- 缓存缺失时从插件指定的 HTTPS 地址下载，设置超时并重试；下载先写到独立临时文件，校验通过后才进入缓存。
- 保留插件自己的原始完整性校验。失败时给出实际下载状态、文件位置和预期校验值。

默认共享缓存：`%LOCALAPPDATA%\consumable_build_cache\media_kit`。需要调整时，可设置 `SOHUN_MEDIA_KIT_CACHE_DIR`。直接执行 Flutter 构建和使用项目构建脚本都会经过同一套校验。

`scripts/test_media_kit_cache.cmake` 的 3 项验证通过：有效缓存替换空文件、有效构建文件填充新缓存、损坏缓存被拒绝。测试使用临时构造的文件，不访问网络。

项目构建脚本另修复了返回码问题：`robocopy` 返回 1 表示成功复制，不能作为整个构建的失败退出码；现在成功构建明确返回 0。

## 构建命令

在 `电脑软件` 目录运行：

```powershell
.\scripts\build_windows.ps1 -Configuration Debug
.\scripts\build_windows.ps1 -Configuration Release
```

项目路径包含中文时，该脚本在临时英文路径编译，再将完整程序复制回 `dist/windows/personal/<Configuration>`，避免原生工具链路径编码问题。

Debug 与 Release 均已编译成功。Release 构建脚本退出码为 0，输出目录为 `电脑软件/dist/windows/personal/Release`，包含 `sohun.exe`、`libmpv-2.dll`、ANGLE DLL 和 Flutter 资源。检查了 x64 PE 架构及 12 个必需文件均非空。

构建日志：`电脑软件/build/fix-windows-debug-build.log`、`电脑软件/build/fix-windows-release-build.log`。构建期间仍有第三方插件的 CMake 开发者提示，但未再发生视频依赖校验失败。

个人版安装包已生成，Windows PE 文件头检查通过：

- 文件：`电脑软件/dist/installer/sohun-setup-1.0.0-1-windows-x64.exe`
- 大小：140284951 字节
- 生成时间：2026-09-06 01:15:08（本地时间）
- SHA256：`0067a7ad076610754e3ec67f14b764445bdde0ae23346a182884682476dacddb`
- 安装包构建日志：`电脑软件/build/fix-personal-installer.log`

验收包含测试、静态检查、Debug / Release 编译及安装包生成，未执行覆盖安装或真实打印机硬件验收。

最终一次 `dart analyze lib test` 返回 0，无 error / warning，有 214 条 info 提示，详见 `电脑软件/build/fix-release-analyze.log`。这是本次所检查范围的结果，不代表整个软件所有功能已完成验收。
