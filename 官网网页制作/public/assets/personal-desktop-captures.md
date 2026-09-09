# 个人桌面端截图来源

首页当前使用 `personal-workspace-v4.png` 与 `personal-inventory-v4.png`，于 2026-09-08 从本轮统一玻璃按钮后的 Flutter 客户端渲染产物直接复制，分别展示真实 `AuroraWorkspace` 工作台与 `InventoryScreen` 库存页。两张图均为浅色个人模式，逻辑窗口 1360 × 900，3 倍像素比的 PNG 为 4080 × 2700。未绘制、裁剪、调色或替换界面内的按钮；官网资产与原始产物的 SHA-256 一致。

生成入口：`电脑软件/test/personal_desktop_visual_test.dart`，工作目录为 `电脑软件`：

```powershell
flutter test --no-pub --concurrency=2 --dart-define=CAPTURE_DESKTOP_UI=true --update-goldens --plain-name '桌面玻璃预览 light' test/personal_desktop_visual_test.dart
```

该测试挂载真实客户端组件和 `PersonalDesktopTheme`，使用客户端的 `#00B42A` 主色、内存数据库及 12 条示例耗材。示例数据不代表用户的实际库存。测试不读取真实账户、不连接打印机、不启动后台业务；字体通过 Windows 微软雅黑测试字体加载器渲染。截图属于当前客户端组件的渲染结果，并非原生 Windows 安装包或真实硬件验收记录。

| 官网资产 | 原始产物 | SHA-256 |
| --- | --- | --- |
| `personal-workspace-v4.png` | `电脑软件/build/all-buttons-ui/desktop-ui/workspace-light.png` | `876A56B86AD1F40D2E749439CA1EE365EBD35E17AC7AC91D63E658D83A9F0DEE` |
| `personal-inventory-v4.png` | `电脑软件/build/all-buttons-ui/desktop-ui/inventory-light.png` | `569C3EE506A17D623C177F32FFA91D9399287D88442928C4970AA93A16086233` |

测试默认输出 `电脑软件/build/desktop-ui/`，本轮客户端任务把最终截图归档至 `电脑软件/build/all-buttons-ui/desktop-ui/`，官网从该归档复制。官网静态资源测试检查当前资源的 HTTP 响应、PNG 签名及画布尺寸。

旧版 v3 资产及其静态 URL 保留供历史链接访问，首页不再引用：

| 历史官网资产 | 当时原始产物 | SHA-256 |
| --- | --- | --- |
| `personal-workspace-v3.png` | `电脑软件/build/desktop-ui/workspace-light.png` | `C559544CFC32EBEA9C57B9F17C30244925F5B38AAF765928663628BC11D2D399` |
| `personal-inventory-v3.png` | `电脑软件/build/desktop-ui/inventory-light.png` | `D7903C4199F35A1A5433C160D21F8DC16278A50759AAF6ECBD95820EA62B2DF6` |
