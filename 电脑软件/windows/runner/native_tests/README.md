# Windows RFID 串口层无硬件回归

此目录只验证 Windows COM 传输，不验证 RC522 接线、卡片兼容性或写卡成功。
默认测试完全使用 fake backend，不打开真实串口、不复位设备、不烧录。

## 构建与运行

在已加载 Visual Studio C++ 工具链的 PowerShell 中，使用单独的英文输出目录：

```powershell
$rfidNativeBuild = Join-Path $env:TEMP ('sohun_rfid_native_' + [Guid]::NewGuid().ToString('N'))
cmake -S .\windows\runner\native_tests -B $rfidNativeBuild
cmake --build $rfidNativeBuild --config Release
ctest --test-dir $rfidNativeBuild -C Release --output-on-failure
```

还可使用已安装 Flutter SDK 的 Windows 引擎缓存，编译并运行真实消息编解码器
的 MethodChannel 契约测试（不创建 Flutter 引擎、不打开应用界面）：

```powershell
$rfidFlutter = flutter --version --machine | ConvertFrom-Json
$rfidEngine = Join-Path $rfidFlutter.flutterRoot 'bin/cache/artifacts/engine/windows-x64'
cmake -S .\windows\runner\native_tests -B $rfidNativeBuild "-DSOHUN_FLUTTER_ENGINE_DIR=$rfidEngine"
cmake --build $rfidNativeBuild --config Release
ctest --test-dir $rfidNativeBuild -C Release --output-on-failure
```

传入的缓存必须已有 SDK 的 `flutter_windows.dll`、导入库及 C++ wrapper。
该测试使用 fake messenger 和 fake serial backend，并通过不可见的
message-only window 验证后台通知返回平台线程。没有实物卡片或真实 COM 写入。

可选的只读 PnP 元数据检查（同样不会打开串口）：

```powershell
& (Join-Path $rfidNativeBuild 'Release\desktop_rfid_serial_transport_test.exe') --list-ports
```

覆盖严格端口名、单连接、连接代次、旧 read/write/close 隔离、二进制完整性、
8192 字节边界、读写错误失效、写超时不冒充成功、32 请求队列上限、顺序完成、
慢驱动下的非阻塞销毁与晚到回调清理。Flutter 窗口/MethodChannel 集成还需执行
项目 `scripts/build_windows.ps1 -Configuration Release`；真机拔线与读写另行验收。

MethodChannel 测试额外覆盖：生产通道名、参数校验、`Uint8List` 与普通 List
区分、准确的字段名、错误码及 Windows details、空成功结果、平台线程回包、
单次完成，以及销毁时取消所有未交付结果并注销 handler。

全应用构建应等待当前 Dart 分析与专项测试通过后只执行一次；若要保留用户已有
`build/windows` 和 `dist/windows`，先复制当前工程到独立 ASCII 快照，再从该
快照调用原有 `scripts/build_windows.ps1 -Configuration Release`。不要使用旧
快照里的 Dart 文件来验收新 UI；完成后将整个运行目录另存为套件预览，不能只
复制 exe（Flutter、插件、资源、MSVC runtime 都属于必需运行文件）。

## Dart 契约

MethodChannel：`top.sohun/desktop_rfid_serial`，只在个人版 Windows 注册。

| 方法 | 参数 | 成功结果 |
| --- | --- | --- |
| `listPorts` | 无 | `List<Map>`：`port`、`label`、可选 `hardwareId` |
| `open` | `{port: "COM5"}` | `{connectionId: "rfid-..."}` |
| `read` | `{connectionId}` | `Uint8List`，0 至 8192 字节 |
| `write` | `{connectionId, bytes: Uint8List}` | `null`，完整交付驱动后返回 |
| `close` | `{connectionId}` | `null` |

端口必须为 `COM1` 至 `COM65535` 的大写规范形式，不接受路径或前导零。
枚举仅提供当前在场 PnP 串口，不主动探测任何端口；CH340/VID 只是候选信息，
不能证明是本品牌套件，必须由 Dart 完成协议版本与能力握手。

串口固定 115200、8N1，无硬件/软件流控，DTR/RTS disabled；不主动切换复位脚。
某些板卡/驱动仍可能在打开串口时复位，因此不能把 `open` 当作套件 ready。
`read` 只取当前缓冲；写入使用驱动 1500 ms 超时和后台 2000 ms 外层期限。
Win32 上报拔线时返回 `disconnected`；驱动未上报时仍需 Dart 心跳/协议超时兜底。
`write` 成功仅表示传输成功，绝不表示卡片已写入或已校验。

错误码：`invalid_arguments`、`busy`、`port_busy`、`stale_connection`、
`disconnected`、`serial_unavailable`、`serial_configuration_failed`、
`serial_io_error`、`serial_timeout`。details 为 Windows 错误数字（无则 0）。
读写错误立即使当前连接失效，不自动重发半帧；上层必须重新连接并重新握手。
旧连接的任何请求无法触及新连接；活跃连接尚未关闭时 `open` 返回 `busy`。

所有串口 API 都在单后台线程执行，完成结果用无指针的窗口消息交回 Flutter
平台线程。窗口退出立即取消并丢弃排队任务；后台自持资源直到 Windows 确认
OVERLAPPED 完成，杜绝销毁后回调引擎或提早释放 I/O 缓冲。
异常第三方驱动可能延迟响应取消，这不会阻塞 UI 销毁；在它释放句柄前，该
端口可能仍被系统判定占用。原始卡片/串口数据不记录到日志。

## API 依据

- [Microsoft：通信资源独占句柄](https://learn.microsoft.com/en-us/windows/win32/devio/communications-resource-handles)
- [Microsoft：COM 超时与立即返回缓冲字节](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-commtimeouts)
- [Microsoft：DCB、DTR/RTS 与流控配置](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-dcb)
- [Microsoft：CancelIoEx 与完成后才能释放 OVERLAPPED](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)
- [Microsoft：仅枚举当前在场的设备](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetclassdevsw)
- [Microsoft：设备友好名称与硬件标识](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceregistrypropertyw)
