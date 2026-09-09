# sohun RFID 移动端工作台（历史浏览器原型）

> 此目录已废弃，不是当前移动端，也不会被 Android 构建使用。它只保留早期网页交互草稿，
> 其中的 AMS 读取、桥接模拟和库存同步说明均不代表现行实现。当前手机端请从同一个桌面
> Flutter 工程构建：`电脑软件/lib/main_mobile.dart`，原生 Android NFC 入口位于
> `电脑软件/android/`。

这是与个人版桌面软件保持同一信息层级的移动端工作台。界面使用桌面版的极光绿、浅灰背景、玻璃面板和分组导航，面向两条核心路径：先写入耗材标签，再从 AMS 读取并加入耗材库。

## 当前能力

### RFID 写入与校验

1. 在“RFID 写入”页填写品牌和耗材类型（必填），并补充颜色、型号、净重、批次号和备注。
2. 检查写入预览中的 AMS 识别字段，确认后由 BambuRfidReader 桥接设备执行写入。
3. 工作流会经过“写入中”和“校验中”，只有 UID、品牌和耗材类型读回匹配后才登记为成功。
4. 成功记录会加入本地耗材库和操作记录，并进入待同步队列；桥接在写入期间断开会进入可重试的错误态，不会登记半写入标签。

### AMS 读取入库

“AMS 读取”页提供 AMS 01 的槽位选择。读取结果包含品牌、耗材类型、颜色、剩余重量、标签 UID、托盘 UUID 和协议；确认后可直接加入耗材库。没有 UID 的未知槽位不能入库。

### 库存与操作记录

移动端库存沿用桌面个人版的主要字段：

`manufacturer`、`model`、`materialType`、`colorHex`、`colorName`、`totalGrams`、`remainingGrams`、`uid`、`trayUuid`、`batchNo`、`note`、`updatedAt`、`source`。

写入、AMS 读取和入库事件会保留来源和 UID，库存页、操作记录页、成本页和工作台指标均从同一份状态派生，不再依赖固定的静态记录。

## 账号与同步边界

### sohun 登录

设置 `VITE_SOHUN_API_BASE_URL` 后，登录会调用现有接口：

```text
POST {VITE_SOHUN_API_BASE_URL}/v1/auth/login
Content-Type: application/json

{"email":"name@example.com","password":"..."}
```

例如（PowerShell）：

```powershell
$env:VITE_SOHUN_API_BASE_URL = "https://api.sohun.top"
```

未配置该变量时，浏览器使用本地演示适配器，仅用于体验界面流程。演示不会保存密码；当前返回的 API 会话令牌只在内存中经过登录边界，原生 Android/iOS 版本应迁移到 Keystore/Keychain，并补充刷新和退出登录流程。

### 与桌面版同步

`src/syncAdapter.js` 是同步传输边界。当前实现是本地演示适配器：登录后等待一小段时间，更新本地修订号、同步时间和待同步数量，不会向服务器发送库存数据。

现有 sohun 服务目前只有农场 Studio 快照同步契约，没有个人耗材库接口。因此，真正实现“手机与个人版电脑软件共用耗材库”还需要服务端提供个人范围的库存/操作记录接口（例如 `/v1/me/inventory`），并定义账号鉴权、`revision`/冲突合并、删除或覆盖语义。接入接口时只需替换 `syncAdapter.push`，界面中的本地队列和状态展示可以继续复用。

## RFID 协议与硬件限制

浏览器版本不能直接访问手机 NFC 或 USB；当前页面用桥接状态和延迟回调模拟完整交互。生产版需要把 BambuRfidReader 的 Android NFC/USB 读写实现接入原生壳，再通过同一套字段和事件模型驱动页面。

参考的开源项目是 [BambuRfidReader / 3DPrint-Filament-RFID-Tool](https://github.com/m0h31h31/3DPrint-Filament-RFID-Tool)，其典型链路为 NFC 读取、MIFARE 数据解析、持久化和写入/克隆操作。

Bambu 官方标签使用 MIFARE Classic，并包含加密和签名；普通手机 NFC 或未经正确签名的数据不代表 AMS 会接受。字段能否被 AMS 识别还取决于标签类型、密钥、签名和设备固件，具体限制见 [Bambu Lab RFID Tag Guide](https://github.com/Bambu-Research-Group/RFID-Tag-Guide)。页面因此会明确提示“外置桥接”和“写入后读回校验”，不会把普通 NFC 模拟成官方标签兼容。

## 本地运行

```powershell
Set-Location "<仓库路径>\手机软件"
npm install
npm run dev -- --port 4178
```

打开 `http://localhost:4178/`。生产构建和预览：

```powershell
npm run build
npm run preview -- --port 4179
```

如需清空浏览器演示数据，可在开发者工具执行：

```js
localStorage.removeItem('sohun-rfid-mobile-store-v2')
location.reload()
```

## 后续接入清单

- 接入原生 BambuRfidReader 桥接：实际扫描、MIFARE 密钥、加密写入、签名校验和错误码。
- 增加 sohun 个人库存 API，并在 `syncAdapter` 中实现上传、拉取、修订冲突和离线重试。
- 在原生端使用 SQLite 保存库存/操作记录，使用 Keystore/Keychain 保存短期访问令牌和刷新令牌。
- 将 AMS 真实托盘数据映射到 `trayUuid`、`remainingGrams` 等桌面字段，并验证官方标签在目标固件上的接受结果。
