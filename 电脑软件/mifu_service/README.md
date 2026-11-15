# Mifu 本地决策服务

Mifu 是由 Sohun 项目作者自主设计与训练的数值决策模型及配套集群工作流。当前自研核心 **Mifu Core** 使用本项目的两两数值比较网络与独立训练权重，可脱离兼容基础模型、分词器和SDK离线运行。它不是聊天模型，也不生成可供展示的“思维链”。

本地已有完成训练的原生数值头及离线测试证据；**尚无取得生产验收资格的模型**，未将研究权重自动接成线上ready。桌面HTTP、采集和旧兼容训练入口继续保留，不会把通用基础模型改署为自研。无已验收权重时服务仍返回 `unconfigured`，不编造概率。产品、自研范围及组件来源见 [Mifu](../../docs/mifu.md) 与 [组件信息](../../docs/mifu-components.md)。

## 1. Mifu Core原生模型与本机服务

### 独立原生模型

原生入口是 `mifu_native.py`，使用 `requirements-native.txt`（PyTorch），不安装兼容SDK、分词器或基础模型。运行环境需预先准备，本入口不会联网安装、下载或发起训练。

```powershell
# 导出到尚不存在的新目录；保持选定权重原始字节和FP64精度
python mifu_native.py export --experiment <已锁定数值实验目录> --out <新原生包目录>

# 使用包内入口；请求是单个mifu-decision-v4 JSON，不是JSONL
python <原生包目录>/mifu_native.py infer --package <原生包目录> --request <请求.json>
```

默认按当前时间检查快照；`--now-epoch 0`仅用于明确以0为时间基准的离线夹具，不用于把过期业务数据变新。可用 `--expected-manifest-sha256 <可信摘要>` 固定包身份。输出的 `scores` 是候选偏好分，不是校准置信度或打印成功概率。

原生包包括数值权重、架构配置、共享输入契约、独立入口和技术溯源附录；不带基础模型、tokenizer、SDK、数据缓存或组合头。包内文件严格校验，请不要把输出或其他文件写进包中。导出不会改动旧实验，也不会生成生产验收或ready。正式HTTP接入仍需单独完成原生运行设置和真实质量验收。

### 直接启动未配置HTTP服务

需要 Python 3.10+；模型环境建议另建隔离虚拟环境，具体Python/PyTorch版本及运行设备需要单独验收。未配置HTTP服务只依赖Python标准库；原生数值推理和对应模型测试需要PyTorch，兼容训练/推理另用其固定依赖。

在本目录运行：

```powershell
./start_mifu.ps1
# 等价：python mifu_server.py
```

桌面客户端默认连接 `http://127.0.0.1:27961`。退出当前终端或按 Ctrl+C 停止服务。脚本不会安装依赖、下载、注册后台服务或修改防火墙。

有经过独立质量验收的旧兼容训练产物时（此路径使用单独的 `requirements.txt`，不能传原生包）：

```powershell
./start_mifu.ps1 -Python ./.venv/Scripts/python.exe -Checkpoint ./checkpoints/mifu-v1 -Device cuda
```

也可以由操作员配置 `MIFU_CHECKPOINT`。启动后异步加载，健康状态依次为 `loading` → `ready` 或 `error`。现在还必须通过 `acceptance_report.json` 的建议质量门槛：绑定权重、完整分词器及配置哈希、明确输入版本、真实复核记录和未参与调参的独立验收。服务仅接受实际验收过的候选数量；`ready` 仍不授权自动执行。HTTP支持 `legacy_v1` 和 `mifu-decision-v4`，按已验收模型的inputContract精确匹配；新实验权重仍不具有生产资格。重新配置模型后需要重启服务。

### 本机访问边界

- 仅绑定 `127.0.0.1`，没有 `--host`、公网或局域网监听选项。
- `Host` 必须精确为实际端口的 `127.0.0.1:<port>`；拒绝 `localhost`、域名和重复 Host，防 DNS rebinding。
- 拒绝所有 `Origin` / `Sec-Fetch-*` 浏览器请求，无 CORS，POST 仅接收 JSON。
- 默认允许本机原生桌面客户端；可选 `MIFU_API_TOKEN`（至少24个ASCII字符），客户端发送 `Authorization: Bearer ...`。不把令牌放到URL、代码或日志里。
- 默认模式不能隔离同一电脑上的其他原生进程；共享电脑建议启用令牌并使用操作系统用户权限隔离。HTTP端点不能传模型路径、训练路径、脚本或指令，不能启动打印机。
- 推理和结果事件请求体最大64KiB；采集原始选择快照的 `/v1/records` 单独允许256KiB，以保留多台AMS的完整证据。最多8个连接槽、单次串行模型推理；GPU查询最多1.5秒、缓存3秒。推理若底层GPU长时间阻塞，需要终止并重启服务；客户端应设超时，不承诺Python线程可以安全中止CUDA计算。
- 本地服务强制 Hugging Face/Transformers 离线，缺失权重即失败，不偷偷联网拉取基础模型。

## 2. HTTP 契约

### 新版输入检查与在线比较

桌面读取 `/health` 的 `supportedInputContracts` 及 `model.inputContract/supportedObjectives`。支持v4时，集群“检查条件”可先检查当前快照；已验收v4模型的“重新决策”使用相同请求先检查再比较。两者均通过居中窗口填写逐台取件、换板、换料的预计准备秒数，默认留空，只有操作员明确输入0才视为零。填写期间盘、设备或切片变化则作废；快照/设备时间超过120秒拒绝。

`POST /v1/decisions/check` 接收与v4推理相同的 `{requestId,plate,candidates,decision_context}`，返回 `evidenceStatus`、`tokenAudit`、`modelReady`、`canInfer` 和中文 `issues`。没有已验收v4 tokenizer时仅作结构预检，tokenAudit为pending且canInfer=false，不返回choice或概率。在线拒绝synthetic来源及未验收的availability降级目标。

v4使用与训练一致的 `build_decision_input` 投影、2048/1024 token预算与parallel选项布局。`setup_seconds`保留人工估计来源；等待来自设备/队列的下界，单次耗时来自绑定SHA的切片估计。这些不是实际测量或总完工时间保证。当前候选检查范围仍为既有精确机型、喷嘴、供料、耗材与队列，`full_geometry_verified=false`明确保留，未获得完整碰撞/物理适配证明。

2026-11-12已在4070隔离目录用当前共享输入构造器和SDK实际完成2/4/8/16候选兼容性检查，均无截断、选项丢失或CPU回退；模型、配置和分词器加载前后及推理后完整文件哈希一致。实际使用BF16 autocast，不是此前保留评估的FP32，不能继承其94%正确率或校准结论。二候选样例仍选中了预计完成较晚的设备；4/4通过只指输入/运行/输出兼容，不表示4次决策均正确，不形成生产资格。详情见隔离GPU兼容性报告（原始报告保留本地，不随公开源码分发）。

v4完整快照可以记录，历史采集不恢复其推理新鲜度；未填完整准备时间时仍可使用原始人工观察采集。现已提供独立的 `reviewed_v4_export.py` 人工复核导出，见下文。原 `training.py` 导出/训练仍只处理legacy，遇到v4或待分词审核文件明确拒绝，不能静默按旧格式训练。

### 验收与实际运行设置绑定

服务现要求 `mifu-advisory-acceptance-v2`，在原有权重/输入/质量门槛之外绑定 `runtimeProfile`。旧v1验收不能直接复用，需按实际运行设置重新验收。`mifu-runtime-profile-v1` 记录实际设备类型、单问题行数、计算精度与autocast、参数dtype、eager后端、fast/compile开关、attention实现、eval状态，以及CPU回退和AMP失败计数。

实际精度读取SDK运行路径，不从checkpoint里声明的 `amp_dtype` 猜测。加载器显式保持 `fast=False, compile=False, backend='eager'`；初始化、推理前后及异常路径均检查。发现精度/设备/运行设置漂移、临时CPU回退或AMP重试时撤销ready并丢弃该次建议。FP32评估和校准不能直接授权BF16运行。

该门槛约束可观测运行策略，并非逐算子精度、TF32或全部硬件数值等价证明；也不会把实验权重自动转成已验收模型。

选中盘的 `toolpath_geometry` 已进入采集：有界解释明确模式下的直线/XY圆弧、坐标和挤出状态，记录各工具正向挤出指令中心线范围并绑定切片/盘/Gcode哈希。未知宏、变换、缺失完整性或超出限额时为待核实；中心线不是含线宽、工具偏移和碰撞空间的完整占用。当前真实仓库样本未附Gcode，实际样本适配尚未验收。

### `GET /health`

```json
{
  "service": "mifu",
  "apiVersion": 1,
  "status": "ok",
  "trainingState": "unconfigured",
  "model": {
    "name": "Mifu",
    "version": null,
    "base": null,
    "engine": null,
    "checkpointConfigured": false,
    "device": null,
    "evaluation": null,
    "autoExecutionEnabled": false
  },
  "lastError": null,
  "host": {
    "gpuName": null,
    "utilizationPercent": null,
    "memoryUsedMb": null,
    "memoryTotalMb": null,
    "temperatureC": null
  }
}
```

`trainingState` 为 `unconfigured | loading | ready | error`；桌面连接失败时自行显示“未连接”，不把未连接和待训练混在一起。`status: ok` 只是服务存活。`host` 来自真实 `nvidia-smi` 的第0张GPU，不支持/失败的值为 `null`；它和 `model.device` 是两件事，检测到4070不等于模型正用GPU推理。实际SDK退回CPU时 `model.device` 显示CPU。

### `POST /v1/decisions`

```json
{
  "requestId": "decision-001",
  "plate": {
    "id": "plate-01", "taskId": "task-01",
    "material": "PETG", "estimatedMinutes": 92, "requiredGrams": 75
  },
  "candidates": [
    {"id": "printer-01", "features": {"queueMinutes": 20, "materialReady": true}},
    {"id": "printer-02", "features": {"queueMinutes": 50, "materialReady": false}}
  ]
}
```

每次只对**一盘**比较2–16个候选。所有候选先由桌面业务逻辑检查硬约束；本服务不代替尺寸、耗材兼容、余量、在线状态和占用校验。多盘任务应按每次选择更新队列/物料预留，避免都看到同一份空闲快照。只有一个候选时展示唯一适配设备，不虚构模型比较。

成功响应：

```json
{
  "requestId": "decision-001", "trainingState": "ready",
  "choice": "printer-01",
  "probabilities": {"printer-01": 0.7, "printer-02": 0.3},
  "elapsedMs": 18.42,
  "model": {
    "name": "Mifu", "version": "v1", "base": "laya-multilingual",
    "checkpointConfigured": true, "device": "cuda:0",
    "evaluation": "held_out", "autoExecutionEnabled": false
  }
}
```

以上数值仅用于说明协议，不是性能或成功率承诺。`elapsedMs` 实际测量SDK调用耗时。`probabilities` 是候选选择概率，不是打印成功率；拒绝截断、未知候选、NaN、无效概率及不一致结果。服务只返回建议，不自动启动打印；即使基础训练完成，也需要独立测试集上的成本/稳定性/校准验收。

SDK内部使用 `candidate_00` 等中性标签，并映射回真实设备ID；任务ID、盘ID、包ID和名称不进入推理上下文。物理槽位 `resource_id` 改为候选内匿名 `resource_slot: slot_0`，同一候选的多个工具共享槽位关系仍然保留，不让模型记忆数据库ID。UI应展示候选概率、输入盘、排除原因和真实耗时，不伪造“内部思考”、权重贡献或GPU利用率。候选特征过长也可能超过token预算并被拒绝，此时需缩小候选范围或简化非必要特征，不能无提示截断。

错误返回 `{ "error": { "code": "...", "message": "..." }, "trainingState": "...", "requestId": "可选" }`：

| HTTP | 含义 |
| --- | --- |
| 400 / 413 / 415 / 422 | 无效请求、过大、非JSON、特征/候选无效 |
| 401 / 403 | 令牌无效、非本机Host或浏览器请求 |
| 429 | 正在处理另一项推理 |
| 502 | 模型返回非法结果或输入被截断 |
| 503 | 尚未配置、加载失败或本次推理失败 |

### `POST /v1/records`

```json
{
  "request": {"requestId": "decision-001", "plate": {"id": "plate-01", "taskId": "task-01"}, "candidates": [{"id": "printer-01", "features": {}}, {"id": "printer-02", "features": {}}]},
  "decision": null,
  "feedback": "observed",
  "selectedCandidateId": null,
  "outcome": {"waitMinutes": 20, "actualMinutes": 96, "failed": false}
}
```

`feedback` 为 `accepted | corrected | observed`，接受/纠正必须指定候选；可附完整DecisionResponse。返回201：`{"recordId":"UUID","trainingEligible":false}`。

记录追加到固定的 `data/feedback.jsonl`。接受、修改、观察都只是未经独立审核的反馈，**不会自动变成“最优答案”标签**；`decision` 也是客户端提交的未验证事实，不作为可靠模型审计签名。同一完整载荷重复送达时返回原recordId及 `duplicate:true`，使用文件锁并确认写入磁盘后回执；改变快照或选择会形成新观察。没有整份文件下载、删除或指定文件路径接口。

采集允许1–16台候选；只有一台候选时不能附模型比较结果，也不会进入排名训练集。桌面同时保存 `mifu-observation-v1`：同一次快照的时间、切片哈希/盘号、实际报告机型/喷嘴、AMS类型/物理挤出路径与槽位观测。没有观测的AMS与明确为空分开；字段级时间、几何全层投影、准备耗时和维修评估未取得时保留未知。设备/AMS/槽位上限分别16/256/1024，超过边界明确拒绝，不截取后半段作为完整快照。

### 打印结果与人工质检

集群先选择打印盘并“记录选择”，之后打开居中的“打印结果”窗口。当前入口为人工录入，不要求模型处于ready：

1. 选择历史原始选择，为本次打印建立独立批次；每次重打使用新的attemptId。
2. 记录执行状态、实际开始/结束时间、用时、用料及失败线索；没有测量的值留空。
3. 在同一批次单独记录人工质检。机器完成、尚未质检、无法判断、合格、返工、不合格分别保留。
4. 已有数据需要更正时追加更正事件及原因。网络回执不确定时重试同一eventId和同一payload，不新建一条重复结果。

质检更正保留原检查人，并单独记录执行更正的人；重新检查使用新质检事件。超过64台可见设备时，客户端按64台分块查询、去重合并并按时间排序，仍遵守最近20条选择/100个批次的展示上限，达到上限时有明确提示。

`POST /v1/records/query` 接收 `{plateId, candidateIds}`，只查询当前打印盘和可见设备范围，返回最近20条原始选择及最近100个批次。`POST /v1/outcomes` 接收 `outcome_collection.py` 定义的execution或quality事件，追加到 `data/outcomes.jsonl`；不覆写旧事件，也不触发打印。记录按原反馈、盘和候选哈希绑定，身份漂移、重复ID内容冲突或损坏记录会被拒绝。

查询中的可见设备范围由桌面传入，用于避免混入当前界面以外的记录；它不是服务端独立验证的账号授权。目前服务面向同一Windows用户的本机采集，尚不具备多租户身份认证和隔离。共享账号或多人服务器使用前必须补齐可信账号绑定，不能把本机范围过滤宣传为多用户隔离。

如果实际打印开始早于快照采集，标记 `snapshotCapturedAfterStart=true` 并说明不能作为事前调度标签；时间证据不足则保留未知。所有结果仍是 `trainingEligible=false`，实际完成不自动证明选择最优或成品合格。当前没有自动把旧数据库记录回填成事前候选快照，也未自动接收全部打印机结束事件；后续设备事件接入需先建立真实执行批次与原始选择的可靠关联。

特征禁止密码、令牌、访问码、IP地址和序列号等字段。此检查不等于完整脱敏；调用方仍应仅提供必要的结构化特征，避免姓名/客户文本和任何自由文本里的秘密。本机原始反馈受当前用户文件权限保护，公开共享前必须审核。

## 3. 人工复核与训练集

收集任务/盘特征、合格候选、实际选择、真实等待与耗时、重打、耗材消耗。以下旧格式流程仅适用legacy。由了解排程的人员结合结果复核，用独立文件写标签：

```json
{"recordId":"实际采集返回的UUID","selectedCandidateId":"printer-01","reviewSource":"expert_review","reviewer":"operator-01","rationale":"比较该时刻可用设备及实际排队结果后确认"}
```

每行一个JSON。`reviewSource` 只允许 `expert_review` / `controlled_experiment`，不是 `accepted`。这些字段记录来源，不是对审核真实性的密码学证明。

```powershell
python training.py export --labels ./reviewed-labels.jsonl --out ./datasets/mifu-v1
```

导出 `train.jsonl`、`eval.jsonl`、`dataset_report.json` 到**新目录**，不会覆盖原文件。按任务ID分组后确定性划分，保证同任务的多盘不跨训练/评估；缺少任务ID或完全相同状态跨集合会拒绝。至少两个任务仅为格式门槛，不表示样本量足够。还需检查近重复任务、时间外评估和候选顺序偏差。

最终Laya训练行使用 `{state, questions, expected:{printer:"candidate_00"}}`，保留动态候选。导出默认去掉盘/任务标识和任务名称，不使用设备ID作模型标签。

### v4独立人工复核导出

在本目录执行，所有输出必须使用尚不存在的新路径：

```powershell
python reviewed_v4_export.py template --records ./data/feedback.jsonl --out ./reviews-v4.jsonl
python reviewed_v4_export.py export --records ./data/feedback.jsonl --labels ./reviews-v4.jsonl --out ./datasets/reviewed-v4-pending --seed 4070
python reviewed_v4_export.py export --records ./data/feedback.jsonl --labels ./reviews-v4.jsonl --out ./datasets/reviewed-v4-audited --tokenizer C:/models/laya/tokenizer --seed 4070
```

模板中的episode、选择、审核人、理由与审核时间由人工补充，不将“接受建议”或实际选择直接当最优标签。导出校验记录/请求摘要与候选绑定，拒绝冲突、重复复核及已知仿真标记。客户端账本来源声明和审核人身份尚未认证；摘要证明内容绑定，不证明这些记录实际来自打印机。

任务、episode、快照、完全相同及候选换序等价输入按传递关系合并后，再划分 `train/validation/calibration/heldout`。至少需要4个有多候选排名样本的独立组；单候选不参与排名训练，但保留其组间连接，防止借单候选桥接造成跨集合泄漏。该门槛不是足够样本量的保证，近重复与时间外泛化仍需另验。

没有本地tokenizer时只产生 `pending_*.jsonl`，不能直接训练。指定tokenizer后使用与线上相同的 `build_decision_input`，逐条审核2048/1024预算，全部通过才写正式四个split及来源/审核/代码/输出哈希。历史时间保留，不恢复在线新鲜度。导出不启动训练、不生成生产manifest、不授予ready；校准与heldout不得用于拟合或选模型。

导出专项24项测试通过，另用本地真实Laya tokenizer对8条明确构造的测试夹具完成CPU端导出实测，覆盖2/4/8/16候选，四份split实际产生5/1/1/1条。全量审核最长837 tokens、选项25 tokens，tokenizer摘要不变，CUDA始终未初始化。夹具不是实机记录或人工复核标签，此检查不测模型质量。报告：真实tokenizer导出检查（原始报告保留本地，不随公开源码分发）。

## 4. RTX 4070 训练入口

先人工准备隔离环境、匹配驱动的CUDA版PyTorch、固定 `requirements.txt` 依赖，以及**本地已下载完整的 multilingual 权重目录**（需有 `rl_agent_config.json`、`model.safetensors`、`tokenizer/`、`encoder/`）。安装和下载应作为单独明确的操作；本项目脚本不会代为进行。Laya和基础权重均按Apache-2.0声明，分发仍需保留相应许可并核对依赖。

先只检查数据和参数，无SDK、tokenizer或GPU加载：

```powershell
./train_4070.ps1 -BaseCheckpoint C:/models/laya-multilingual `
  -TrainingData ./datasets/mifu-v1/train.jsonl `
  -EvaluationData ./datasets/mifu-v1/eval.jsonl `
  -OutputDirectory ./checkpoints/mifu-v1 -Version v1 -DryRun
```

确认数据、显存与环境后，去掉 `-DryRun` 才会真正训练。默认微批1、累积8、冻结编码器、混合精度、梯度检查点和候选顺序打乱；`-FullFinetune` 显式开启全量训练。相关低显存起步参数已在4070上完成一轮合成实验，但该轮验证正确率未改善，不能据此保证领域效果；全量编码器微调尚未实测。

训练调用官方 `laya.train.finetune`，要求单独 `--eval`、禁止训练/评估完全相同输入、禁止覆盖已有输出。训练结束只生成 `candidate_manifest.json`，不再自动把“训练跑完”变成可加载模型。它绑定权重、分词器、配置和数据哈希。通过单独质量验收后才能形成正式 `mifu_manifest.json` 与匹配的 `acceptance_report.json`；当前没有任何实验产物获得该资格。manifest不是签名证明，只加载可信操作员生成的本地模型。

训练结果需要比较：总完工时间、迟交、换料次数、设备负载、失败/重打、模型建议被修改比例、不同候选顺序的一致性。官方基础模型在部分通用决策测试零样本接近随机，因此不能假设下载后就会正确调度打印机。

### 独立数值排序适配器实验（2026-11-13）

`mifu_numeric_ranker.py` 增加离线数值学习分支：整数先做差，再以FP64学习完成时间差和准备时间差，不向模型传入正确设备、排名或设备名称。`train_numeric_adapter.py` 分别训练numeric-only和hybrid；原H Laya权重冻结，对照结果与确定性计算基线分别记分。没有接入生产HTTP加载器，不会生成ready或替换原模型。

独立新目录按顺序执行（缓存/最终评估需要已准备的4070环境与原H权重）：

```powershell
python train_numeric_adapter.py dry-run --out <新实验目录>
python train_numeric_adapter.py prepare --out <新实验目录>
python train_numeric_adapter.py cache --out <新实验目录> --checkpoint <原H目录>
python train_numeric_adapter.py train --out <新实验目录>
python train_numeric_adapter.py evaluate --out <新实验目录> --checkpoint <原H目录>
```

先完成源码定版再prepare；缓存、SDK、输入、完整checkpoint和选定适配器均绑定SHA。固定4096训练/512验证基础场景，每组2048次更新；选定权重后才生成4096例新留出。重复调用旧256题只能作为开发回归，不能重新称独立测试。所有来源仍为合成排序样本，数值分支得分不等于原Laya本体得分，也不等于真实打印成功率。

具体设计及边界见数值适配器实验说明（研发记录保留本地；公开范围见 [Mifu说明](../../docs/mifu.md)）。315项后端回归通过，0失败、0跳过；这不替代模型质量或真机验收。

本轮实际完成：新留出非全平局3584题，数值/组合分支均100%，原H单独22.46%；未见数值投影3394题两新分支均100%。旧256题的新数值头开发回归100%；额外宽域压力1904道非全平局也100%。两组各训练2048更新，最终按验证策略保存第128步。数字分别属于不同架构/测试范围，不可宣传为原Laya或全业务100%。完整结果与逐题证据（研发记录保留本地；公开范围见 [Mifu说明](../../docs/mifu.md)）。

## 5. 验证与已知边界

```powershell
python -m unittest discover -s tests -v
```

服务单测使用stub，包含真实127.0.0.1 HTTP、待训练状态、输入/输出契约、Host/Origin/令牌防护、反馈落盘、离线导出分组、权重校验和4070训练计划。另已在远端4070独立环境完成真实SDK基础模型加载、三次GPU预测和一轮合成实验；这与正式HTTP服务接入、领域效果和实机打印验收分别记录。

仍未完成：真实领域训练和校准、稳定吞吐基准、长时间多盘调度效果、全量编码器训练、实机打印执行。此服务没有打印机凭据，不负责实际启动、暂停或修改打印任务。训练输出和manifest本身都不代表业务质量合格。

官方依据：[Laya项目](https://github.com/NandhaKishorM/laya)、[模型卡](https://huggingface.co/convaiinnovations/laya)、[训练说明](https://github.com/NandhaKishorM/laya/blob/main/docs/finetune.md)、[HTTP协议](https://github.com/NandhaKishorM/laya/blob/main/docs/http-api.md)。

## 6. 按场景准备训练（2026-11-12）

百万规模硬件模拟、不同AMS的边界挑战与分层实验入口见大规模硬件数据准备（研发记录保留本地；公开范围见 [Mifu说明](../../docs/mifu.md)）。新模拟布局 `mifu-hardware-sim-v3` 尚未接入线上推理，所有产物明确不可部署；数据生成不代表完成训练。

最新紧凑 `mifu-decision-v4` 混合候选实验已在4070完成2,048次更新。同一400条模拟验证集从32.25%提升至94.50%；冻结权重后的800条独立模拟留出正确率94.00%（2/4/8/16候选分别97%/96%/91.5%/91.5%）。校准阈值仅来自另800条校准记录，保留79.875%的建议时总体98.28%，但16候选保留部分仍只有94.84%。此结果不能证明真实质检、维修或生产调度能力，不生成生产manifest，也没有把v4权重接到旧在线输入。

2026-11-13另完成一次固定512更新的近差/候选换序定向微调，实际2,048次抽样涉及1,625个新训练场景。训练前后在同一新256例、同一BF16口径下，正确率66/256→64/256，换序一致性89.06%→61.33%；锁定新权重后的新256例留出为76/256（29.69%）。这轮未改善，不部署，原H完整文件未改。该分布让候选运行/等待/准备耗时独立组合，不能和旧94%或192例诊断指标组成版本曲线。报告见定向训练结果（原始报告保留本地，不随公开源码分发）。

2026-11-13加入v4人工复核导出与实际运行设置门槛后，后端完整回归262项全部通过（97.242秒，无跳过）。桌面既有结果客户端/弹窗28项通过；刀路/声明几何/观察/规划58项回归通过；客户端、输入构造、界面与决策生命周期首轮44项通过；最终v4输入与完整交互专项7项通过，覆盖无已验收模型时的条件检查、居中准备耗时窗口、未知与0的区分、预检和推理使用同一份输入，以及取消再次比较后旧建议仍按时失效。上述测试范围有重叠，不累加为独立测试总数。当前历史查询有20条选择/100批次展示上限，尚无翻页；操作人标识为本地匿名标识，不等于认证账号身份。完整刀路占用与真实结果自动关联仍是后续工作。

`training_curriculum.json` 将原设计的46个场景映射到11条训练/验收路径，明确哪些使用当前输入、哪些需要未来特征、哪些属于非模型硬约束。

`prepare_curriculum.py --out <新目录>` 生成覆盖报告、复核模板和带来源标记的240条管线模拟记录。它不采集真实业务、不训练、不生成部署清单。模拟内容仅验证当前字段下的等待时间比较，不宣称覆盖全部领域能力。

`run_curriculum_experiment.py --bundle <准备目录> --base <本地基础模型> --out <新实验目录> --dry-run` 可先检查实验计划；实际执行只生成实验产物。正式训练入口拒绝这些带 `synthetic_pipeline_only` 标记的模拟样本，避免误生成可部署Mifu；这项保护不代替真实数据来源与复核审计。
