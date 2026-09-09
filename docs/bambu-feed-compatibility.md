# 拓竹机型与发布打印供料规则

核对日期：2026-09-05。适用范围：桌面软件的打印机配置、耗材绑定、个人项目发布打印和队列发送。型号清单按官方 Bambu Studio 的 `machine_model_list` 核对，共 14 个独立型号。Combo、激光套装不是新增打印机型号；X1 与 X1 Carbon、H2D 与 H2D Pro 分别保留。

## 机型矩阵

“四槽 AMS”指初代 AMS / AMS 2 Pro，共享四槽设备配额；AMS HT 每台一个槽。以下为兼容固件和对应连接附件下的上限，不代表用户当前安装情况。物理外挂位与同一任务可同时使用的来源分别计算。

| 型号 | 四槽 AMS 上限 | AMS HT 上限 | 常规 AMS 总台数上限 | AMS Lite | 本体外挂路径 | 同一任务最大颜色数 |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| X1 | 4 | 4 | 4 | 不支持 | 1，可切换 | 16 |
| X1 Carbon / X1C | 4 | 4 | 4 | 不支持 | 1，可切换 | 16 |
| X1E | 4 | 4 | 4 | 不支持 | 1，可切换 | 16 |
| P1P | 4 | 4 | 4 | 不支持 | 1，可切换 | 16 |
| P1S | 4 | 4 | 4 | 不支持 | 1，可切换 | 16 |
| P2S | 4 | 4 | 8 | 不支持 | 1，可切换 | 20 |
| A1 | 4 | 4 | 4 | 1 台，与常规 AMS 二选一 | 1，可切换 | 16 |
| A1 mini | 4 | 4 | 4 | 1 台，与常规 AMS 二选一 | 1，可切换 | 16 |
| A2L | 4 | 4 | 4 | 1 台，可混接 | 1，可切换 | 19 |
| X2D | 4 | 8 | 12 | 不支持 | 2，按左右路由判断 | 25 |
| H2D | 4 | 8 | 12 | 不支持 | 2，按左右路由判断 | 25 |
| H2D Pro | 4 | 8 | 12 | 不支持 | 2，按左右路由判断 | 25 |
| H2C | 4 | 8 | 12 | 不支持 | 2，按左右路由判断 | 25 |
| H2S | 4 | 8 | 12 | 不支持 | 1，可切换 | 24 |

上限不能相加误用。例如 X1C 的 4 台上限允许 3 台四槽 AMS + 1 台 HT，不允许 4 台四槽 AMS 再加 4 台 HT。P2S 的最大 20 色为 4×4+4；双路径 H2/X2D 的最大 25 色需要 24 个 AMS 槽位服务一侧，另一侧使用一卷外挂。两侧都由 AMS 占用时不能再加两个外挂颜色。H2D Pro 的配额采用官方兼容指南的 H2 系列规则，其独立型号及随附 AMS 2 Pro、AMS HT 由官方型号列表及发布说明确认。

以上数字依据[官方跨机型 AMS 兼容指南](https://wiki.bambulab.com/en/ams/manual/multi-model-AMS-compatibility-guide)、[X2D FTS 指南中的扩展上限](https://wiki.bambulab.com/en/general/manual/filament-track-switch)、[A2L 接线指南](https://wiki.bambulab.com/en/a2l/manual/a2l-ams-connection-guide)、[官方机型列表](https://github.com/bambulab/BambuStudio/blob/master/resources/profiles/BBL.json)和[H2D Pro 发布说明](https://blog.bambulab.com/bambu-lab-launches-h2d-pro-for-enterprise-manufacturing/)。

## 不能再混淆的关系

- X1C 等单路径机器接上 AMS 后，外挂仍是物理可切换来源，库存绑定需要保留；它不增加一个可与 AMS 同时打印的独立颜色。切换需完成实际进退料。界面显示、数据库绑定、打印命令不能共用一个“外挂数量为零”的判断。[官方固件说明](https://blog.bambulab.com/firmware-update-20220926/)
- X2D 左喷头为直接挤出的主喷头，右喷头为辅助喷头。不能用协议常量 `MAIN_EXTRUDER_ID` 的名称推断产品角色，也不能把耗材工具 T0/T1 当成左右喷头。程序采用切片所选盘的喷头分配和设备实际 AMS 路由核对。[官方 X2D 挤出系统说明](https://blog.bambulab.com/two-extruders-one-purpose-what-is-x2d-direct-drive-extrusion-and-auxiliary-extrusion/)
- 双路径机器的一侧 AMS + 另一侧外挂可以共同打印。是否还剩一路外挂，取决于 AMS 实际接入哪侧，不能仅按 AMS 台数判断。两台 AMS 都接同侧，另一侧仍可能留给外挂；两侧各有 AMS，则两路外挂都需要切换。支撑料用途由切片决定，不按名称自动猜喷头。
- A2L 单独使用 AMS Lite 有 4 路；混接时用户让出任意一路进料口给常规 AMS，Lite 余下 3 路。保存全部 24–27 物理编号，禁止写死第四槽失效。4 台四槽 AMS + 3 路 Lite = 19 色；界面的物理料位数量不能当成同时可打印颜色数。[官方 A2L 接线步骤](https://wiki.bambulab.com/en/a2l/manual/a2l-ams-connection-guide)
- FTS（Filament Track Switch）允许共享 AMS 供料，拓扑不同于固定左右进料。官方 X2D 指南要求使用外挂前移除 FTS。当前软件识别共享路由后保守拦截未经确认的自动发送，提示使用 Bambu Studio；这不等于已经完成 FTS 自动动态路由支持。[官方 FTS 指南](https://wiki.bambulab.com/en/general/manual/filament-track-switch)
- H2C 的换热端数量不等于独立进料路径数量。只接受明确的左右挤出路径分配；未知编号保持未知。

## 连接条件

X1/P1 单 AMS 使用对应缓冲器，多 AMS 使用 AMS Hub；不能把各机型缓冲器当成通用附件。P2S 使用其专用缓冲器。A1/A1 mini 连接常规 AMS 需要 A1 专用 AMS Hub、固件 01.07.00.00 或更新版本；不能用 X1/P1 的缓冲器或 Hub 代替。A2L 单常规 AMS 使用附带耦合器，多个 AMS 按官方指南增加四合一 PTFE 转接器；H2C 需留意专用连接附件。[官方兼容指南](https://wiki.bambulab.com/en/ams/manual/multi-model-AMS-compatibility-guide)

打印供料与主动烘干是两项能力。X1/P1/A1 的 AMS 2 Pro 烘干需要外接电源；H2/P2S 可由打印机支持一台 AMS 2 Pro 烘干，其余依要求供电。不要据此推断所有新机型的电源条件。耗材兼容性同样不能只按“TPU”一词一概允许或禁止，应区分 AMS 专用 TPU、普通柔性料、具体送料系统及喷嘴条件；当前机型配额校验不宣称覆盖每种耗材配方。[官方兼容指南](https://wiki.bambulab.com/en/ams/manual/multi-model-AMS-compatibility-guide)

## 协议边界与状态处理

| 来源 | 本地通道 / 传感器位序 | `ams_mapping` | `ams_mapping2` |
| --- | --- | --- | --- |
| 四槽 AMS | 0–15 | 0–15 | 实际 AMS ID 0–3、槽号 0–3 |
| AMS HT | 16–23 | 128–135 | AMS ID 128–135、槽号 0 |
| A2L AMS Lite | 24–27 | 24–27 | AMS ID 16、槽号 0–3 |
| 左外挂 | 254 | -1 | AMS ID 254、槽号 0 |
| 右/单外挂 | 255 | -1 | AMS ID 255、槽号 0 |
| 未参与的工具 | -1 | -1 | AMS ID 255、槽号 255 |

双挤出机物理编号 0 对应 R，1 对应 L；虚拟外挂与物理挤出机按此关联。逻辑喷头映射优先读取切片配置，不能按材料序号推断。旧单挤出机 `tray_now=254` 表示当前使用外挂，这是一个状态编码，不能直接拿来当左外挂命令编号。混接 Lite 的单元存在位是 bit 12，不是物理 AMS ID 16 对应的 bit 16。[官方 DevDefs](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevDefs.h)、[DevFilaSystem](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevFilaSystem.cpp)、[DevExtruderSystem](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevExtruderSystem.cpp)、[发送映射实现](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/SelectMachine.cpp)

MQTT 采用增量上报。按单元和槽位 ID 合并更新；温湿度更新不能删掉旧槽位、RFID 身份或喷头路由。缺少有料位掩码、缺少另一侧传感器，均为未知，不作为空槽解绑。AMS 使用中的挤出传感器不能触发外挂拔料事件。断线重连清除上一连接的缓存，等待新事实。路由和 RFID UID 变化必须参与消息去重比较。

## 已落地的发送检查

统一规则位于 `电脑软件/lib/data/seed/printer_seed.dart`、`printer_feed_models.dart` 和 `bambu_print_feed.dart`，页面、队列及 MQTT 发送边界共同使用，避免每页复制机型特例。

发送时复核目标机器、LAN 新鲜状态、切片机型和喷嘴、参与工具映射、实际装料槽位、左右喷头分配及同路 AMS/外挂冲突。个人项目还复核绑定耗材的材质、颜色、余量和预留，并以文件哈希避免入队后文件被替换。多盘文件使用工单关联的盘号；所选盘不存在时不改发别盘。上传前再次验证，未确认接收时不显示发送成功，也不自动重复尝试。

## 后续修改的检查要求

1. 运行 `powershell -File scripts/verify_bambu_feed.ps1 -CheckOfficialCatalog`。官方新增或删除型号时必须人工核对并更新矩阵，不能仅把新名字塞进已有机型分支。
2. `bambu_feed_capabilities_test.dart` 的独立期望覆盖 14 个型号、混接配额及协议映射；`bambu_feed_incremental_test.dart` 覆盖稀疏上报、库存绑定、X2D 左主右辅、FTS 拦截和 A2L 非固定保留口。
3. 联动测试覆盖耗材换料、外挂机制、队列实发前检查、多盘选择、个人库存隔离及添加机器页面。修改后还需通过现有 CI 的完整 Flutter 测试。
4. 新固件、新 AMS 类型、新共享附件没有确认协议时，保留未知并阻止猜测发送。真实硬件验收应记录打印机/AMS 固件、附件、接管路径、切片版本和实际结果；纯软件测试不能替代所有机型实机试打。

本次没有向真实打印机发送测试打印。已确认的硬件能力、软件模拟验证、尚未支持的动态路由分别记录，避免把“测试通过”写成“所有固件和硬件组合均已实测”。

## 本轮验证记录

- 官方型号清单检查通过：14 款，与独立核对清单一致。
- 完整桌面 Flutter 测试：808 项通过，1 项需提供本地 Bambu Studio 和多盘文件的测试未启用。
- 供料专项检查：243 项通过。末次针对型号后缀识别、数字 FTS 状态的修改，另在独立构建目录运行能力矩阵和增量状态 20 项测试，全部通过；独立目录用于避开其他测试进程对 Windows 原生库的占用。
- 最终 `dart analyze lib test`：0 个错误、0 个警告；项目仍有格式类提示。
- 添加打印机页面的预期布局已更新，页面回归测试通过。本轮未生成或安装新的 Windows 安装包，也未执行全部机型的实机打印验收。
