# 个人版玻璃按钮

个人桌面和手机版使用同一套玻璃按钮材质：半透明填充、14px 背景模糊、细高光边缘，以及悬停和按压反馈。危险操作保留红色，禁用状态、加载状态、键盘焦点及系统减少动画偏好继续生效。

`applyGlassButtonTheme` 只由 `buildPersonalDesktopTheme` 和 `buildMobileTheme` 安装。商业主题没有 `GlassButtonsTheme` 标记，原样式分支保持不变。

## 页面接入

- 常规 `FilledButton`、`ElevatedButton`、`OutlinedButton`、`TextButton`、`IconButton` 直接继承主题，保留 Flutter 的点击、长按、键盘和语义行为。
- 有局部 `style` 的按钮使用 `glassButtonStyle(context, 原样式, variant: ...)`，保留尺寸、内边距等布局参数，并从原颜色中保留危险／提示等语义色。未启用玻璃主题时返回同一个原样式。
- 自绘操作使用 `AppGlassButton`；可传 `tint`、`padding`、`minimumSize`、`borderRadius`、`child`、`tooltip`，保持紧凑控件尺寸。复杂 SVG 图标通过按钮内部 `IconTheme` 获取前景，避免在浅玻璃上写死白色。
- Flutter 的 `SegmentedButton` 会重建内部按钮样式并丢弃背景构建器，因此外包 `GlassSegmentedSurface`，选择逻辑和几何布局仍由原控件负责。
- 手机选择胶囊使用 `MobileGlassChoiceChip`，内部保留真实 `ChoiceChip` 及其选中、勾选和回调。普通状态标签、整卡片、导航项、输入字段和图表不是操作按钮，不转换交互语义。

材质与调色统一在 `电脑软件/lib/widgets/glass_button_material.dart`；标准按钮接入在 `电脑软件/lib/core/theme/glass_button_theme.dart`。不要在不同页面复制另一套实色按钮背景或叠加多次同款玻璃层。

## 验证

基础材料、主题隔离、危险色、按钮边缘点击、Enter 激活和分段选择见 `test/glass_button_theme_test.dart`。手机和桌面真实页面分别见 `test/mobile_ui_regression_test.dart`、`test/personal_desktop_visual_test.dart`，按[开发工作流](development-workflow.md)使用 `--concurrency=2`。

可选预览参数为 `CAPTURE_MOBILE_UI=true`、`CAPTURE_DESKTOP_UI=true`、`CAPTURE_UPDATE_UI=true`。预览使用隔离的内存库存和模拟账号／NFC；图片中的示例数据不代表真实账户或设备操作。
