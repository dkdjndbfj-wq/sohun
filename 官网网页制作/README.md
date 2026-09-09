# sohun 官网网页

这是从主软件仓库中独立提取的官网项目，包含：

- 软件介绍首页，含个人端工作台与耗材库存的真实界面截图
- 参数广场，含搜索、筛选、分页与参数详情
- 订单号和访问密码入口
- 登录后的订单 HLS 视频与生产进度页面
- 多台正在打印设备切换
- 无打印任务时的固定黑屏状态
- 桌面和手机响应式布局
- 独立的品牌 404 页面，保留 HTTP 404 状态并提供常用返回入口

## 目录

```text
官网网页制作/
  public/assets/        网站图片
  screenshots/         历史桌面和手机预览图
  src/site_theme.js     全站设计变量、图标、导航和页脚
  src/marketing_site.js 首页、订单入口和提示页模板
  src/marketing_styles.js 营销页面与订单入口样式
  src/product_showcase.js 真实客户端截图切换与功能介绍
  src/product_styles.js 产品展示区样式
  src/download_section.js Windows/Android 下载区与平台推荐
  src/not_found.js      自定义 404 页面
  src/parameter_site.js 参数广场模板、样式和交互
  src/public_site.js    页面导出与订单实时进度模板
  src/server.js         独立网站服务器和后端代理
  test/server.test.js   独立网站测试
```

## 本地启动

需要 Node.js 24 或更高版本。

1. 先启动原有社区服务器，默认地址为 `http://127.0.0.1:27861`。
2. 在本目录运行：

```powershell
npm start
```

3. 打开 `http://127.0.0.1:27870/`。

首页和订单入口可以独立显示。公开参数、订单登录、实时进度、SSE 和自托管 MediaMTX HLS 视频需要连接社区服务器。
访问 `/404` 或其他不存在的页面可查看自定义 404。页面不自动跳转，也不依赖 JavaScript；首页、下载区、参数广场和订单查询入口均可直接使用。
首页直接展示从当前 Flutter 个人客户端渲染的工作台与耗材库存截图，可切换页面或打开原图。截图中的库存为隔离的演示数据，界面没有重绘或调色；生成来源见 `public/assets/personal-desktop-captures.md`。参数广场展示社区服务返回的真实公开内容。

页面使用个人桌面端的 `#F4F6F5` 底色、`#00B42A` 极光绿及白色半透明玻璃材质。正文强调色为 `#006C19`，主按钮使用浅绿半透明填充与 `#005A15` 深绿文字；次按钮、图标按钮和链接型操作沿用透明玻璃、高光细边及轻阴影。`site_theme.js` 的 `glassButtonStyles` 统一 14px 背景模糊、悬停、按压、键盘焦点和禁用状态；不支持背景模糊时使用可读的不透明底色。普通导航和正文链接保持原有布局。

所有页面复用同一套导航、字体、按钮和设计变量；手机导航无需 JavaScript，截图切换支持方向键，并遵循系统的减少动态效果设置。更新按钮样式时在所属页面保留尺寸与语义，仅复用共享表面和状态，避免页面专有的实色或悬停规则覆盖玻璃效果。

## 配置

```powershell
$env:HOST='127.0.0.1'
$env:PORT='27870'
$env:COMMUNITY_BACKEND_ORIGIN='http://127.0.0.1:27861'
npm start
```

生产部署时，建议让反向代理把公网域名指向此网站服务器，并把
`COMMUNITY_BACKEND_ORIGIN` 配置为内网社区服务器地址。不要把社区数据库复制到官网目录。
导航和页脚的“下载客户端”先定位到首页下载区，分别展示 Windows 与 Android 安装包。浏览器按操作系统推荐版本：Android 手机优先安卓版，Windows 电脑优先桌面版；iPhone/iPad 提示暂无对应客户端。推荐不依赖屏幕宽度，无 JavaScript 时仍可手动选择平台。

下载区根据服务器配置显示可下载或“安装包正在准备中”。Windows 下载按钮通过 `/download`
重定向；生产环境设置 `SOHUN_DOWNLOAD_URL` 为 GitHub Release 中真实的 Windows 安装包 HTTPS 地址。
未设置时不会显示可下载按钮，直接访问下载入口会返回 503 提示页。

NTAG213 设备标签使用 `/device/<32位小写十六进制标识>` 作为应用入口。网页只提供
“打开 sohun”链接，不查询设备资料；设备权限由登录后的应用检查。链接解析拒绝额外路径、查询参数和非规范标识。

Android 下载使用独立的 `SOHUN_ANDROID_DOWNLOAD_URL`，配置不含凭据、查询参数或片段的
HTTPS `.apk` 文件地址；入口为 `/download/android`。默认空值会显示“Android 安装包正在准备中”，
不会转到 Windows 下载。正式安装包和站点部署依照仓库发布门禁准备；此配置不会自动部署应用或验证 Android App Links。

## 测试

```powershell
npm test
```
