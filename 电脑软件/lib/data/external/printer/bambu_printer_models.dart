/// 拓竹打印机 MQTT 协议数据模型。
///
/// 拓竹打印机内置 MQTT broker（端口 8883 TLS），通过 LAN 直连。
/// 云模式通过 cn.mqtt.bambulab.com / us.mqtt.bambulab.com 连接，
/// 协议与 LAN 完全相同。
///
/// **主题结构**：
/// - 订阅：`device/{serial}/report`（打印机状态上报）
/// - 发布：`device/{serial}/request`（发送指令）
///
/// **认证**：
/// - LAN：username=`bblp`，password=LAN Access Code
/// - Cloud：username=`u_xxx`（JWT）或 token 本身（opaque token），password=accessToken
///
/// **上报模式**：
/// - `pushall`：一次性推送全部状态（连接时主动请求）
/// - `pushing`：增量推送状态变化（实时）
///
/// **增量消息处理**（重要）：
/// `pushing` 消息只含变化字段，缺失字段为 null。`fromMqttJson` 对缺失字段
/// 返回 null，`copyWith` 只更新非 null 字段，避免默认值覆盖有效数据。
library;

import '../../models/rfid_tag_identity.dart';
import 'bambu_fault_codes.dart';

/// 打印机 G-code 状态枚举。
enum BambuGcodeState {
  idle('idle', '空闲'),
  running('running', '打印中'),
  pause('pause', '已暂停'),
  finish('finish', '已完成'),
  failed('failed', '已失败'),
  init('init', '初始化中'),
  prepare('prepare', '准备中'),
  offline('offline', '离线'),
  slicing('slicing', '切片中'),
  unknown('', '未知');

  final String code;
  final String label;
  const BambuGcodeState(this.code, this.label);

  static BambuGcodeState fromCode(String code) {
    // 拓竹 MQTT 实际上报大写（RUNNING/PAUSE/IDLE/...），枚举 code 用小写。
    // 这里做大小写归一化，兼容两种情况。
    final lower = code.toLowerCase();
    for (final s in BambuGcodeState.values) {
      if (s.code == lower) return s;
    }
    return BambuGcodeState.unknown;
  }

  /// 是否在活跃打印中（消耗耗材）
  bool get isConsuming => this == BambuGcodeState.running;

  /// 是否可暂停
  bool get canPause => this == BambuGcodeState.running;

  /// 是否可恢复
  bool get canResume => this == BambuGcodeState.pause;

  /// 是否可停止
  bool get canStop =>
      this == BambuGcodeState.running ||
      this == BambuGcodeState.pause ||
      this == BambuGcodeState.init ||
      this == BambuGcodeState.prepare;

  /// 是否处于终态（任务结束）
  bool get isTerminal =>
      this == BambuGcodeState.finish || this == BambuGcodeState.failed;

  /// 是否是过渡态（init/prepare）：打印机正在切换状态，应保持当前任务状态不变
  bool get isTransient =>
      this == BambuGcodeState.init || this == BambuGcodeState.prepare;
}

/// 拓竹打印速度档位。MQTT `print_speed.param` 使用 1..4 的档位编号，
/// `spd_mag` 才是打印机回传的实际倍率，两者不能混用。
enum BambuSpeedProfile {
  silent(1, 50, '静音'),
  standard(2, 100, '标准'),
  sport(3, 124, '运动'),
  ludicrous(4, 166, '狂暴');

  const BambuSpeedProfile(this.level, this.nominalPercent, this.label);

  final int level;
  final int nominalPercent;
  final String label;

  static BambuSpeedProfile fromTelemetry({int? level, int? multiplier}) {
    for (final profile in values) {
      if (profile.level == level) return profile;
    }
    final value = multiplier ?? 100;
    if (value <= 75) return silent;
    if (value <= 112) return standard;
    if (value <= 145) return sport;
    return ludicrous;
  }

  static bool isValidLevel(int level) =>
      values.any((profile) => profile.level == level);
}

/// 打印机实时状态快照。从 MQTT pushall/pushing 消息解析。
///
/// **所有字段均可空**：pushing 增量消息只含变化字段，缺失字段为 null。
/// copyWith 只更新非 null 字段，保留旧值。UI 使用时用 `?? 默认值`。
class BambuPrinterStatus {
  final String serial;

  /// G-code 状态（null = 增量消息未含此字段）
  final BambuGcodeState? gcodeState;

  /// 打印进度百分比（0-100，按 G-code 行数算）
  final int? mcPercent;

  /// 剩余时间（分钟）
  final int? mcRemainingTime;

  /// 当前层号
  final int? currLayer;

  /// 总层数
  final int? totalLayers;

  /// 当前使用的 AMS 槽位（"0"=T0, "1"=T1...）
  final String? trayNow;

  /// 喷嘴当前温度
  final double? nozzleTemper;

  /// 喷嘴目标温度
  final double? nozzleTargetTemper;

  /// 热床当前温度
  final double? bedTemper;

  /// 热床目标温度
  final double? bedTargetTemper;

  /// 风扇档位
  final int? fanGear;

  /// 速度倍率
  final int? spdMag;

  /// 速度档位编号：1=静音、2=标准、3=运动、4=狂暴。
  final int? spdLvl;

  /// AMS 状态码
  final int? amsStatus;

  /// 打印阶段。22=退料，24=进料；其余值由固件用于打印准备/校准等阶段。
  final int? mcPrintStage;

  /// 旧协议的挤出机耗材传感器状态。1=有料，0=无料。
  final int? hwSwitchState;

  /// 新协议各挤出机的耗材传感器状态，按挤出机 id 排列。
  final List<bool?>? extruderFilamentPresent;

  /// 外置料盘（旧协议 `vt_tray` / 新协议 `vir_slot`）。
  ///
  /// 外置料盘没有 AMS RFID 身份，信息仅用于预填用户在打印机上设置的
  /// 厂商、材质与颜色，不能据此自动认定为同一物理卷。
  final List<AmsTray>? externalTrays;

  /// 当前打印的 G-code 文件名
  final String? gcodeFile;

  /// 子任务名（3MF plate 名）
  final String? subtaskName;

  /// 失败原因（gcode_state=failed 时的诊断信息）
  final String? failReason;

  /// 打印错误代码（从 print.print_error 解析，拓竹固件以 hex 字符串或整数形式上报）。
  ///
  /// 与 [failReason] 互补：failReason 是人类可读文案，print_error 是结构化错误码。
  /// 同时存在时下游应以 print_error 优先匹配知识库，failReason 作回退。
  final String? printError;

  /// 结构化 HMS 故障列表（从 print.hms 解析）。
  ///
  /// 拓竹 X1C/H2D 等机型通过 HMS 节点上报多个独立故障，每条形如：
  /// `{"code": "0C0030A0001C0001", "attr": [...], "warning": 1}`。
  /// 老固件或非旗舰机型可能不上报此字段，此时为 null。
  /// 同一条 MQTT 消息可含多个 HMS 故障，下游必须逐条处理而非 else if 吞掉。
  final List<PrinterHmsAlert>? hmsAlerts;

  /// Keep explicit clears distinguishable from unreported state after merging.
  final bool hasHmsState;
  final bool hasPrintErrorState;
  final bool hasFailReasonState;

  /// AMS 各槽位耗材详情（从顶层 ams 节点解析）
  final List<AmsTray>? amsTrays;

  /// 已上报的 AMS 单元及其协议类型（从 `ams.ams[]` 解析）。
  ///
  /// null 表示本次增量消息没有 AMS 单元字段；空列表表示设备明确上报当前无 AMS。
  final List<AmsUnit>? amsUnits;

  /// `get_version` 模块名提供的 AMS 类型映射（物理 AMS id -> 类型）。
  ///
  /// 这是明确硬件标识，只在单元 info 缺失或未知时作为补充事实来源。
  final Map<int, AmsUnitType>? amsModuleTypes;

  /// v12 预留：AMS 内部环境湿度（%，AMS 2 Pro / AMS HT 推送）。
  ///
  /// **待抓包确认 MQTT 字段名后补解析逻辑**。ha-bambulab 源码确认
  /// AMS_HUMIDITY 特性存在，但具体 JSON key 需实测。
  /// 解析后用于：AMS 状态条展示 + 高湿度提前触发干燥提醒。
  final int? amsHumidity;

  /// v12 预留：AMS 内部温度（℃，AMS 2 Pro / AMS HT 推送）。
  ///
  /// **待抓包确认 MQTT 字段名后补解析逻辑**。
  final double? amsTemp;

  /// v12 预留：AMS 烘干状态（AMS 2 Pro / AMS HT 烘干箱推送）。
  ///
  /// **待抓包确认 MQTT 字段名后补解析逻辑**。
  /// 解析后用于：烘干进度展示。
  final bool? amsDrying;

  /// 任务来源（local/cloud/lan/idle）。
  /// 标识任务由何处启动，用于区分「打印机屏幕启动」(local) 与「软件发送」。
  final String? printType;

  /// 拓竹任务 ID（屏幕启动的任务也会分配，用于唯一标识一次打印）
  final String? taskId;

  /// 子任务 ID（3MF plate 级别，同 task_id 下可有多个 subtask）
  final String? subtaskId;

  /// 当前固件版本（从 info.module.sw_ver 解析，仅 pushall 推送）
  final String? fwVersion;

  /// 硬件版本（从 info.module.hw_ver 解析）
  final String? hwVersion;

  /// 最新可用固件版本（从 info.module.ota_new_ver 解析，为空表示已是最新）
  final String? otaNewVersion;

  /// 模块名（从 info.module.name 解析，如 "ota"）
  final String? moduleName;

  /// OTA 模块完整信息（从 MQTT info.module 节点解析）。
  /// 含 name/project_name/sw_ver/hw_ver/sn/ota_new_ver 等字段，
  /// 供固件管理面板读取细节信息。
  final Map<String, dynamic>? otaModule;

  /// 升级状态（从 upgrade_ams.status 解析，值为 UPGRADING/UPGRADE_SUCCESS/UPGRADE_FAILED）
  final String? upgradeStatus;

  /// 升级进度百分比（从 upgrade_ams.progress 解析，字符串如 "50"）
  final String? upgradeProgress;

  /// 升级消息（从 upgrade_ams.message 解析，含失败原因等说明）
  final String? upgradeMessage;

  /// 状态时间戳
  final DateTime updatedAt;

  BambuPrinterStatus({
    required this.serial,
    this.gcodeState,
    this.mcPercent,
    this.mcRemainingTime,
    this.currLayer,
    this.totalLayers,
    this.trayNow,
    this.nozzleTemper,
    this.nozzleTargetTemper,
    this.bedTemper,
    this.bedTargetTemper,
    this.fanGear,
    this.spdMag,
    this.spdLvl,
    this.amsStatus,
    this.mcPrintStage,
    this.hwSwitchState,
    this.extruderFilamentPresent,
    this.externalTrays,
    this.gcodeFile,
    this.subtaskName,
    this.failReason,
    this.printError,
    this.hmsAlerts,
    this.hasHmsState = false,
    this.hasPrintErrorState = false,
    this.hasFailReasonState = false,
    this.amsTrays,
    this.amsUnits,
    this.amsModuleTypes,
    this.amsHumidity,
    this.amsTemp,
    this.amsDrying,
    this.printType,
    this.taskId,
    this.subtaskId,
    this.fwVersion,
    this.hwVersion,
    this.otaNewVersion,
    this.moduleName,
    this.otaModule,
    this.upgradeStatus,
    this.upgradeProgress,
    this.upgradeMessage,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 空闲状态工厂（用于无数据时的初始状态）
  factory BambuPrinterStatus.idle(String serial) => BambuPrinterStatus(
    serial: serial,
    gcodeState: BambuGcodeState.idle,
    mcPercent: 0,
    mcRemainingTime: 0,
    currLayer: 0,
    totalLayers: 0,
    trayNow: '0',
    nozzleTemper: 0,
    nozzleTargetTemper: 0,
    bedTemper: 0,
    bedTargetTemper: 0,
    fanGear: 0,
    spdMag: 100,
    spdLvl: BambuSpeedProfile.standard.level,
    amsStatus: 0,
  );

  /// 从 MQTT JSON 消息解析状态。
  ///
  /// **缺失字段返回 null**（不用默认值），这样 copyWith 只更新
  /// 增量消息里实际包含的字段，不会用默认值覆盖旧的有效数据。
  ///
  /// 拓竹消息格式：`{"print": {...}, "ams": {...}, "info": {"command": "pushall"}}`
  static BambuPrinterStatus? fromMqttJson(
    Map<String, dynamic> json, {
    required String serial,
  }) {
    final printData = json['print'];
    final hasPrint = printData is Map<String, dynamic>;
    // 无 print 节点时，仍可能含 info / upgrade_ams（固件升级进度推送）
    if (!hasPrint &&
        json['ams'] == null &&
        json['info'] == null &&
        json['upgrade_ams'] == null) {
      return null;
    }
    final printMap = hasPrint ? printData : const <String, dynamic>{};

    // 解析顶层 ams 节点（AMS 各槽位耗材详情 + AMS 2 Pro/HT 环境数据）
    List<AmsTray>? amsTrays;
    List<AmsUnit>? amsUnits;
    int? amsHumidity;
    double? amsTemp;
    bool? amsDrying;
    List<AmsTray>? externalTrays;
    List<bool?>? extruderFilamentPresent;
    // 标准 MQTT push_status 位于 print.ams；保留顶层 ams 兼容旧固件/中转服务。
    final nestedAmsData = printMap['ams'];
    final amsData = nestedAmsData is Map<String, dynamic>
        ? nestedAmsData
        : json['ams'];
    if (amsData is Map<String, dynamic>) {
      // `ams` 子字段缺失表示本次增量没有更新单元列表；显式 []/{} 才表示清空。
      if (amsData.containsKey('ams') ||
          AmsUnit._parseHex(amsData['ams_exist_bits']) == 0) {
        amsUnits = AmsUnit.parseList(amsData);
        amsTrays = amsUnits
            .where((unit) => unit.isPresent)
            .expand((unit) => unit.trays)
            .toList(growable: false);
      }
      // v12：AMS 2 Pro / AMS HT 推送环境数据，字段在 ams.ams[id] 节点下。
      // 参考 ha-bambulab models.py：humidity(整数%)、temp(整数℃)。
      // 老 AMS / AMS Lite 不推送这两个字段，保持 null。
      //
      // Phase B 修复：拓竹协议中 ams.ams 既可能是 List（标准结构，AmsTray.parseList 也按此解析），
      // 也可能被某些固件或中转服务转成 Map（key 为 "0"/"1"...）。
      // 此处两种结构都要支持，避免运行时 TypeError。
      final amsList = amsData['ams'];
      final List<Map<String, dynamic>> rawAmsUnits = [];
      if (amsList is List) {
        for (final item in amsList) {
          if (item is Map<String, dynamic>) rawAmsUnits.add(item);
        }
      } else if (amsList is Map<String, dynamic>) {
        // 兼容变体：按 key 顺序读取，多数固件使用 "0"/"1"/...
        for (final key in ['0', '1', '2', '3']) {
          final unit = amsList[key];
          if (unit is Map<String, dynamic>) rawAmsUnits.add(unit);
        }
      }
      for (final unit in rawAmsUnits) {
        final h = unit['humidity'];
        if (h is num && amsHumidity == null) {
          amsHumidity = h.toInt();
        }
        final t = unit['temp'];
        if (t is num && amsTemp == null) {
          amsTemp = t.toDouble();
        }
        // 烘干状态：部分固件推送 drying 字段（0/1）
        final d = unit['drying'];
        if (d is num && amsDrying == null) {
          amsDrying = d.toInt() != 0;
        }
        if (amsHumidity != null && amsTemp != null) break;
      }
    }

    final virtualSlots = printMap['vir_slot'];
    if (virtualSlots is List) {
      externalTrays = <AmsTray>[];
      for (var index = 0; index < virtualSlots.length; index++) {
        final raw = virtualSlots[index];
        if (raw is! Map) continue;
        externalTrays.add(
          AmsTray.fromVirtual(
            Map<String, dynamic>.from(raw),
            fallbackSlot: index,
          ),
        );
      }
    } else if (printMap['vt_tray'] is Map) {
      externalTrays = [
        AmsTray.fromVirtual(
          Map<String, dynamic>.from(printMap['vt_tray'] as Map),
          fallbackSlot: 0,
        ),
      ];
    }

    final extruderData = printMap['extruder'];
    if (extruderData is Map) {
      final parsed = <int, bool>{};
      final rawInfo = extruderData['info'];
      final entries = rawInfo is List
          ? rawInfo
          : rawInfo is Map
          ? rawInfo.values.toList(growable: false)
          : const <dynamic>[];
      for (final raw in entries) {
        if (raw is! Map) continue;
        final id = _parseInt(raw['id']);
        final info = _parseInt(raw['info']);
        if (id == null || id < 0 || id > 1 || info == null) continue;
        parsed[id] = ((info >> 1) & 1) != 0;
      }
      if (parsed.isNotEmpty) {
        final maxId = parsed.keys.reduce((a, b) => a > b ? a : b);
        extruderFilamentPresent = [
          for (var id = 0; id <= maxId; id++) parsed[id],
        ];
      }
    }

    // 解析 info 节点（固件版本信息，pushall / get_version 推送）
    // 注意：info.module 可能是单个对象，也可能是数组（多模块）
    String? fwVersion;
    String? hwVersion;
    String? otaNewVersion;
    String? moduleName;
    Map<String, dynamic>? otaModule;
    Map<int, AmsUnitType>? amsModuleTypes;
    final info = json['info'] as Map<String, dynamic>?;
    if (info != null) {
      void captureAmsModule(Map<String, dynamic> module) {
        final parsed = AmsUnit._parseModuleName(module['name']);
        if (parsed != null) {
          (amsModuleTypes ??= <int, AmsUnitType>{})[parsed.key] = parsed.value;
        }
      }

      final moduleRaw = info['module'];
      if (moduleRaw is Map<String, dynamic>) {
        // 单个模块对象
        captureAmsModule(moduleRaw);
        otaModule = moduleRaw;
        fwVersion = moduleRaw['sw_ver'] as String?;
        hwVersion = moduleRaw['hw_ver'] as String?;
        otaNewVersion = moduleRaw['ota_new_ver'] as String?;
        moduleName = moduleRaw['name'] as String?;
      } else if (moduleRaw is List) {
        // 模块数组：优先取 name == 'ota' 的模块（主固件）
        var selectedOta = false;
        for (final m in moduleRaw) {
          if (m is Map<String, dynamic>) {
            captureAmsModule(m);
            final name = m['name'] as String? ?? '';
            if (name == 'ota' || (!selectedOta && otaModule == null)) {
              otaModule = m;
              fwVersion = m['sw_ver'] as String?;
              hwVersion = m['hw_ver'] as String?;
              otaNewVersion = m['ota_new_ver'] as String?;
              moduleName = name;
              selectedOta = name == 'ota';
            }
          }
        }
      }
    }

    // 解析 upgrade_ams 节点（升级状态，升级期间推送）
    String? upgradeStatus;
    String? upgradeProgress;
    String? upgradeMessage;
    final upgradeAms = json['upgrade_ams'] as Map<String, dynamic>?;
    if (upgradeAms != null) {
      upgradeStatus = upgradeAms['status'] as String?;
      upgradeProgress = upgradeAms['progress'] as String?;
      upgradeMessage = upgradeAms['message'] as String?;
    }

    // 解析 print_error（拓竹结构化错误代码，hex 字符串或整数）
    // 与 failReason 互补：failReason 是文案，print_error 是错误码
    final printError = parseBambuPrintError(printMap['print_error']);

    // 解析 HMS 故障列表（拓竹 X1C/H2D 等机型通过 print.hms 上报多个独立故障）
    // 同一条消息可含多个 HMS 故障，下游必须逐条处理而非 else if 吞掉
    //
    // **三态语义**（Phase B 修复）：
    // - 字段缺失（hms key 不存在）：hmsAlerts = null（保留旧值）
    // - 显式空列表（hms: []）：hmsAlerts = []（清除旧值）
    // - 有内容：hmsAlerts = [alert1, alert2, ...]
    List<PrinterHmsAlert>? hmsAlerts;
    final hmsRaw = printMap['hms'];
    if (hmsRaw is List) {
      hmsAlerts = [];
      for (final item in hmsRaw) {
        if (item is Map<String, dynamic>) {
          final alert = PrinterHmsAlert.fromMqttJson(item);
          if (alert != null) {
            hmsAlerts.add(alert);
          }
        }
      }
      // A malformed list must not masquerade as an explicit clear.
      if (hmsAlerts.length != hmsRaw.length) hmsAlerts = null;
    } else if (hmsRaw is Map<String, dynamic>) {
      // 部分固件以 Map 形式上报单条 HMS
      final alert = PrinterHmsAlert.fromMqttJson(hmsRaw);
      if (alert != null) {
        hmsAlerts = [alert];
      }
    }
    // 字段缺失时 hmsAlerts 保持 null（用于 copyWith 保留旧值）
    // 显式空列表时 hmsAlerts 为 []（用于 copyWith 清除旧值）

    return BambuPrinterStatus(
      serial: serial,
      // 缺失字段返回 null，不用默认值
      gcodeState: (printMap['gcode_state'] as String?) != null
          ? BambuGcodeState.fromCode(printMap['gcode_state'] as String)
          : null,
      mcPercent: _parseInt(printMap['mc_percent']),
      mcRemainingTime: _parseInt(printMap['mc_remaining_time']),
      // A1/P1/X1 不同固件使用过两组层数字段。新固件主要上报
      // layer_num / total_layer_num，旧固件与部分代理仍使用 curr_layer。
      currLayer:
          _parseInt(printMap['layer_num']) ??
          _parseInt(printMap['curr_layer']) ??
          _parseInt(printMap['current_layer']),
      totalLayers:
          _parseInt(printMap['total_layer_num']) ??
          _parseInt(printMap['total_layers']) ??
          _parseInt(printMap['total_layer']) ??
          _parseInt(printMap['total_layer_count']),
      trayNow:
          printMap['tray_now'] as String? ??
          (nestedAmsData is Map ? nestedAmsData['tray_now'] as String? : null),
      nozzleTemper: _parseDouble(printMap['nozzle_temper']),
      nozzleTargetTemper: _parseDouble(printMap['nozzle_target_temper']),
      bedTemper: _parseDouble(printMap['bed_temper']),
      bedTargetTemper: _parseDouble(printMap['bed_target_temper']),
      fanGear: _parseInt(printMap['fan_gear']),
      spdMag: _parseInt(printMap['spd_mag']),
      spdLvl: _parseInt(printMap['spd_lvl']),
      amsStatus: _parseInt(printMap['ams_status']),
      mcPrintStage: _parseInt(printMap['mc_print_stage']),
      hwSwitchState: _parseInt(printMap['hw_switch_state']),
      extruderFilamentPresent: extruderFilamentPresent,
      externalTrays: externalTrays,
      gcodeFile: printMap['gcode_file'] as String?,
      subtaskName: printMap['subtask_name'] as String?,
      failReason: printMap['fail_reason'] is String
          ? printMap['fail_reason'] as String
          : null,
      printError: printError,
      hmsAlerts: hmsAlerts,
      hasHmsState: hmsAlerts != null,
      hasPrintErrorState: printError != null,
      hasFailReasonState: printMap['fail_reason'] is String,
      amsTrays: amsTrays,
      amsUnits: amsUnits,
      amsModuleTypes: amsModuleTypes == null
          ? null
          : Map<int, AmsUnitType>.unmodifiable({...?amsModuleTypes}),
      amsHumidity: amsHumidity,
      amsTemp: amsTemp,
      amsDrying: amsDrying,
      // 任务来源标识：local=屏幕启动 / cloud=云端发送 / lan=局域网发送
      printType: printMap['print_type'] as String?,
      taskId: printMap['task_id'] as String?,
      subtaskId: printMap['subtask_id'] as String?,
      // 固件版本信息（info 节点，仅 pushall 推送）
      fwVersion: fwVersion,
      hwVersion: hwVersion,
      otaNewVersion: otaNewVersion,
      moduleName: moduleName,
      otaModule: otaModule,
      // 升级状态（upgrade_ams 节点，升级期间推送）
      upgradeStatus: upgradeStatus,
      upgradeProgress: upgradeProgress,
      upgradeMessage: upgradeMessage,
    );
  }

  /// 合并增量更新：只更新非 null 字段，保留旧值。
  ///
  /// **Nullable 清除语义**（Phase B 修复）：
  /// MQTT 明确给出空 HMS、空失败原因或任务结束时，要能清除旧值；
  /// 字段缺失才保留旧值。Dart 默认参数无法区分"未传"和"显式传 null"，
  /// 因此使用 sentinel 对象：未传 = 保留旧值，显式传 null = 清除。
  /// 调用方必须用 `clearXxx: true` 显式清除，避免误用。
  BambuPrinterStatus copyWith({
    BambuGcodeState? gcodeState,
    int? mcPercent,
    int? mcRemainingTime,
    int? currLayer,
    int? totalLayers,
    String? trayNow,
    double? nozzleTemper,
    double? nozzleTargetTemper,
    double? bedTemper,
    double? bedTargetTemper,
    int? fanGear,
    int? spdMag,
    int? spdLvl,
    int? amsStatus,
    int? mcPrintStage,
    int? hwSwitchState,
    List<bool?>? extruderFilamentPresent,
    List<AmsTray>? externalTrays,
    String? gcodeFile,
    String? subtaskName,
    String? failReason,
    String? printError,
    List<PrinterHmsAlert>? hmsAlerts,
    List<AmsTray>? amsTrays,
    List<AmsUnit>? amsUnits,
    Map<int, AmsUnitType>? amsModuleTypes,
    int? amsHumidity,
    double? amsTemp,
    bool? amsDrying,
    String? printType,
    String? taskId,
    String? subtaskId,
    String? fwVersion,
    String? hwVersion,
    String? otaNewVersion,
    String? moduleName,
    Map<String, dynamic>? otaModule,
    String? upgradeStatus,
    String? upgradeProgress,
    String? upgradeMessage,
    // ===== 显式清除标志 =====
    // 传 true 表示把对应字段置为 null（用于 MQTT 明确空值场景）。
    // 不传或传 false 表示保留旧值（用于字段缺失场景）。
    bool clearFailReason = false,
    bool clearPrintError = false,
    bool clearHmsAlerts = false,
    bool clearGcodeFile = false,
    bool clearSubtaskName = false,
    bool clearTaskId = false,
    bool clearSubtaskId = false,
    bool clearUpgradeStatus = false,
    bool clearUpgradeProgress = false,
    bool clearUpgradeMessage = false,
  }) {
    return BambuPrinterStatus(
      serial: serial,
      gcodeState: gcodeState ?? this.gcodeState,
      mcPercent: mcPercent ?? this.mcPercent,
      mcRemainingTime: mcRemainingTime ?? this.mcRemainingTime,
      currLayer: currLayer ?? this.currLayer,
      totalLayers: totalLayers ?? this.totalLayers,
      trayNow: trayNow ?? this.trayNow,
      nozzleTemper: nozzleTemper ?? this.nozzleTemper,
      nozzleTargetTemper: nozzleTargetTemper ?? this.nozzleTargetTemper,
      bedTemper: bedTemper ?? this.bedTemper,
      bedTargetTemper: bedTargetTemper ?? this.bedTargetTemper,
      fanGear: fanGear ?? this.fanGear,
      spdMag: spdMag ?? this.spdMag,
      spdLvl: spdLvl ?? this.spdLvl,
      amsStatus: amsStatus ?? this.amsStatus,
      mcPrintStage: mcPrintStage ?? this.mcPrintStage,
      hwSwitchState: hwSwitchState ?? this.hwSwitchState,
      extruderFilamentPresent:
          extruderFilamentPresent ?? this.extruderFilamentPresent,
      externalTrays: externalTrays ?? this.externalTrays,
      gcodeFile: clearGcodeFile ? null : (gcodeFile ?? this.gcodeFile),
      subtaskName: clearSubtaskName ? null : (subtaskName ?? this.subtaskName),
      failReason: clearFailReason ? null : (failReason ?? this.failReason),
      printError: clearPrintError ? null : (printError ?? this.printError),
      hmsAlerts: clearHmsAlerts ? null : (hmsAlerts ?? this.hmsAlerts),
      hasHmsState: hasHmsState || clearHmsAlerts || hmsAlerts != null,
      hasPrintErrorState:
          hasPrintErrorState || clearPrintError || printError != null,
      hasFailReasonState:
          hasFailReasonState || clearFailReason || failReason != null,
      amsTrays: amsTrays ?? this.amsTrays,
      amsUnits: amsUnits ?? this.amsUnits,
      amsModuleTypes: amsModuleTypes ?? this.amsModuleTypes,
      amsHumidity: amsHumidity ?? this.amsHumidity,
      amsTemp: amsTemp ?? this.amsTemp,
      amsDrying: amsDrying ?? this.amsDrying,
      printType: printType ?? this.printType,
      taskId: clearTaskId ? null : (taskId ?? this.taskId),
      subtaskId: clearSubtaskId ? null : (subtaskId ?? this.subtaskId),
      fwVersion: fwVersion ?? this.fwVersion,
      hwVersion: hwVersion ?? this.hwVersion,
      otaNewVersion: otaNewVersion ?? this.otaNewVersion,
      moduleName: moduleName ?? this.moduleName,
      otaModule: otaModule ?? this.otaModule,
      upgradeStatus: clearUpgradeStatus
          ? null
          : (upgradeStatus ?? this.upgradeStatus),
      upgradeProgress: clearUpgradeProgress
          ? null
          : (upgradeProgress ?? this.upgradeProgress),
      upgradeMessage: clearUpgradeMessage
          ? null
          : (upgradeMessage ?? this.upgradeMessage),
      updatedAt: DateTime.now(),
    );
  }

  /// 当前固件版本（优先从 MQTT info.module 取）
  String? get currentFirmwareVersion =>
      otaModule?['sw_ver'] as String? ?? fwVersion;

  /// 最新固件版本（云端推送的可用更新版本）
  String? get latestFirmwareVersion =>
      otaModule?['ota_new_ver'] as String? ?? otaNewVersion;

  /// 是否有固件更新可用
  bool get hasFirmwareUpdate {
    final cur = currentFirmwareVersion;
    final latest = latestFirmwareVersion;
    if (cur == null || latest == null) return false;
    if (cur.isEmpty || latest.isEmpty) return false;
    if (latest == 'null') return false;
    // M5 修复：使用语义化版本比较，避免字符串比较导致 1.9.0 > 1.10.0 的错误
    return _compareVersions(cur, latest) < 0;
  }

  /// 当前已连接 AMS 单元的紧凑汇总，仅使用设备协议明确上报的类型。
  ///
  /// 未知类型归入通用 AMS；没有已连接单元时返回 null，调用方不渲染占位。
  String? get amsSummary {
    final units = amsUnits?.where((unit) => unit.isPresent).toList();
    if (units == null || units.isEmpty) return null;

    final counts = <AmsUnitType, int>{};
    for (final unit in units) {
      final moduleType = amsModuleTypes?[unit.id];
      final type = unit.type == AmsUnitType.unknown
          ? (moduleType ?? AmsUnitType.unknown)
          : unit.type;
      counts[type] = (counts[type] ?? 0) + 1;
    }

    // 按产品系列排列；无法确认型号的单元最后以通用 AMS 展示。
    const displayOrder = [
      AmsUnitType.ams,
      AmsUnitType.ams2Pro,
      AmsUnitType.amsHt,
      AmsUnitType.amsLite,
      AmsUnitType.unknown,
    ];
    final parts = <String>[];
    for (final type in displayOrder) {
      final count = counts[type];
      if (count != null && count > 0) {
        parts.add('${type.displayLabel} × $count');
      }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 语义化版本比较：返回 -1(a<b) / 0(a==b) / 1(a>b)
  static int _compareVersions(String a, String b) {
    final partsA = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final partsB = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final maxLen = partsA.length > partsB.length
        ? partsA.length
        : partsB.length;
    for (var i = 0; i < maxLen; i++) {
      final va = i < partsA.length ? partsA[i] : 0;
      final vb = i < partsB.length ? partsB[i] : 0;
      if (va < vb) return -1;
      if (va > vb) return 1;
    }
    return 0;
  }

  /// 是否正在升级中
  bool get isUpgrading => upgradeStatus == 'UPGRADING';

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _parseDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  String toString() {
    final pct = mcPercent ?? 0;
    final layer = currLayer ?? 0;
    final total = totalLayers ?? 0;
    final state = gcodeState?.label ?? '?';
    return 'BambuPrinterStatus($serial: $state, $pct%, layer $layer/$total)';
  }
}

/// 拓竹 HMS 故障告警（X1C/H2D 等机型通过 print.hms 上报）。
///
/// 协议结构：
/// ```json
/// {
///   "attr": 50336256, // 0x03001200：模块、实例、部件
///   "code": 131073   // 0x00020001：严重级别 2、错误 1
/// }
/// ```
/// 组合为 0300120000020001。也接受已经组合好的 16 位字符串。
/// 同一条 MQTT 消息可含多个 HMS 故障，下游必须逐条处理而非 else if 吞掉。
class PrinterHmsAlert {
  /// 16 位 hex 错误码（统一大写）。
  final String code;

  /// 严重级别：info / warning / error。
  final String severity;

  /// 原始附加属性（可空）。
  final List<int> attr;

  /// 原始 JSON（用于调试和持久化）。
  final Map<String, dynamic> raw;

  const PrinterHmsAlert({
    required this.code,
    required this.severity,
    required this.attr,
    required this.raw,
  });

  /// 从单条 HMS JSON 解析。
  /// 返回 null 表示解析失败（code 为空或格式不合法）。
  static PrinterHmsAlert? fromMqttJson(Map<String, dynamic> json) {
    String? code;
    final codeRaw = json['code'];
    final moduleWord = bambuUnsignedWord(json['attr']);
    final errorWord = bambuUnsignedWord(codeRaw);
    if (moduleWord != null && errorWord != null && errorWord != 0) {
      code =
          '${moduleWord.toRadixString(16).padLeft(8, '0')}'
                  '${errorWord.toRadixString(16).padLeft(8, '0')}'
              .toUpperCase();
    } else if (codeRaw is String) {
      final normalized = normalizeBambuFaultCode(codeRaw);
      if (RegExp(r'^[0-9A-F]{16}$').hasMatch(normalized) &&
          !RegExp(r'^0+$').hasMatch(normalized))
        code = normalized;
    } else if (codeRaw is int && codeRaw > 0xFFFFFFFF) {
      code = codeRaw.toRadixString(16).toUpperCase().padLeft(16, '0');
    }
    if (code == null) return null;

    String severity = bambuHmsSeverity(code);
    final warnRaw = json['warning'];
    if (warnRaw is int) {
      switch (warnRaw) {
        case 0:
          severity = 'info';
          break;
        case 1:
          severity = 'warning';
          break;
        case 2:
          severity = 'error';
          break;
      }
    } else if (warnRaw is String) {
      switch (warnRaw.toLowerCase()) {
        case '0':
        case 'info':
          severity = 'info';
          break;
        case '2':
        case 'error':
          severity = 'error';
          break;
      }
    }

    List<int> attr = const [];
    final attrRaw = json['attr'];
    if (moduleWord != null) {
      attr = [moduleWord];
    } else if (attrRaw is List) {
      attr = attrRaw
          .whereType<num>()
          .map((n) => n.toInt())
          .toList(growable: false);
    }

    return PrinterHmsAlert(
      code: code,
      severity: severity,
      attr: attr,
      raw: json,
    );
  }

  @override
  String toString() => 'PrinterHmsAlert($code, $severity)';
}

/// 拓竹协议明确上报的 AMS 单元类型。
///
/// `unknown` 只表示固件已上报该单元，但当前客户端不认识其类型码；
/// 展示时按通用 AMS 处理，不根据槽位数或打印机型号猜测。
enum AmsUnitType {
  ams('AMS 1'),
  amsLite('AMS Lite'),
  ams2Pro('AMS 2 Pro'),
  amsHt('AMS HT'),
  unknown('AMS');

  final String displayLabel;
  const AmsUnitType(this.displayLabel);
}

/// 一个物理 AMS 单元及其槽位。
class AmsUnit {
  final int id;
  final AmsUnitType type;

  /// 从 `info` 低四位或明确的 `ams_type` / `amsType` 字段解析出的原始类型码。
  final int? rawTypeCode;
  final String? rawInfo;

  /// `ams_exist_bits` 明确存在时以其为准；缺失时，已上报的单元视为存在。
  final bool isPresent;
  final List<AmsTray> trays;

  /// 固件 info[8..11] 的物理挤出机编号：0=R，1=L（协议命名不代表机型的主/辅助喷头角色）。
  /// 缺失或 0xE（共享/未绑定）保持未知，不能按 AMS 顺序猜喷头。
  final int? extruderId;

  bool get usesFilamentTrackSwitch {
    final info = _parseHex(rawInfo);
    return info != null && ((info >> 8) & 0xf) == 0xe;
  }

  const AmsUnit({
    required this.id,
    required this.type,
    required this.isPresent,
    required this.trays,
    this.rawTypeCode,
    this.rawInfo,
    this.extruderId,
  });

  /// 从顶层 `ams` 节点解析单元，兼容数组和按 ID 建索引的 Map。
  static List<AmsUnit> parseList(Map<String, dynamic> amsData) {
    final entries = _unitEntries(amsData['ams']);
    if (entries.isEmpty) return const [];

    final existBits = _parseHex(amsData['ams_exist_bits']);
    final hasValidExistBits =
        amsData.containsKey('ams_exist_bits') && existBits != null;
    final trayExistBits = _parseHex(amsData['tray_exist_bits']);

    return List<AmsUnit>.unmodifiable(
      entries.map((entry) {
        final unit = entry.data;
        final id = _parseDecimalInt(unit['id']) ?? entry.fallbackId;
        final rawInfo = unit['info'] is int
            ? (unit['info'] as int).toRadixString(16)
            : unit['info']?.toString();

        // BambuStudio DevFilaSystem 以 info 十六进制值的低 4 位识别型号。
        // 仅当 info 缺失/非法时，才回退到名称明确的类型字段。
        final infoTypeCode = _parseInfoTypeCode(unit['info']);
        final typeCode = infoTypeCode ?? _parseExplicitTypeCode(unit);
        final type = _typeFromCode(typeCode);
        // A2L 的混接 AMS Lite 在协议里使用 type=5、物理 id=16，
        // 但单元存在位固定在 bit 12；不能按普通 AMS 的 id=16 去读 bit 16。
        final existBitIndex = _existBitIndex(id, typeCode: typeCode);
        final isPresent =
            !hasValidExistBits ||
            (existBitIndex >= 0 && (existBits & (1 << existBitIndex)) != 0);

        return AmsUnit(
          id: id,
          type: type,
          rawTypeCode: typeCode,
          rawInfo: rawInfo,
          extruderId: _parseExtruderId(unit['info']),
          isPresent: isPresent,
          trays: List<AmsTray>.unmodifiable(
            AmsTray._parseUnitTrays(
              unit,
              amsId: id,
              mixedAmsLite: typeCode == 5,
              trayExistBits: trayExistBits,
            ),
          ),
        );
      }),
    );
  }

  static List<_AmsUnitEntry> _unitEntries(dynamic rawUnits) {
    final result = <_AmsUnitEntry>[];
    if (rawUnits is List) {
      for (var index = 0; index < rawUnits.length; index++) {
        final raw = rawUnits[index];
        if (raw is Map) {
          result.add(
            _AmsUnitEntry(
              fallbackId: index,
              data: Map<String, dynamic>.from(raw),
            ),
          );
        }
      }
      return result;
    }

    if (rawUnits is Map) {
      final mapEntries =
          rawUnits.entries
              .where((entry) => entry.value is Map)
              .toList(growable: false)
            ..sort((a, b) {
              final aId = _parseDecimalInt(a.key);
              final bId = _parseDecimalInt(b.key);
              if (aId != null && bId != null) return aId.compareTo(bId);
              if (aId != null) return -1;
              if (bId != null) return 1;
              return a.key.toString().compareTo(b.key.toString());
            });
      for (var index = 0; index < mapEntries.length; index++) {
        final entry = mapEntries[index];
        result.add(
          _AmsUnitEntry(
            fallbackId: _parseDecimalInt(entry.key) ?? index,
            data: Map<String, dynamic>.from(entry.value as Map),
          ),
        );
      }
    }
    return result;
  }

  static int? _parseExplicitTypeCode(Map<String, dynamic> unit) {
    for (final raw in [unit['ams_type'], unit['amsType']]) {
      if (raw is num && raw.isFinite && raw == raw.roundToDouble()) {
        return raw.toInt();
      }
      if (raw is! String) continue;
      final trimmed = raw.trim();
      final numeric = int.tryParse(trimmed);
      if (numeric != null) return numeric;

      final normalized = trimmed
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      final code = switch (normalized) {
        'ams' || 'ams_1' => 1,
        'ams_lite' || 'amslite' => 2,
        'ams_lite_mixed' => 5,
        'n3f' ||
        'ams_2' ||
        'ams2' ||
        'ams_2_pro' ||
        'ams2pro' ||
        'ams_2pro' => 3,
        'n3s' || 'ams_ht' || 'amsht' => 4,
        _ => null,
      };
      if (code != null) return code;
    }
    return null;
  }

  static AmsUnitType _typeFromCode(int? code) => switch (code) {
    1 => AmsUnitType.ams,
    2 || 5 => AmsUnitType.amsLite,
    3 => AmsUnitType.ams2Pro,
    4 => AmsUnitType.amsHt,
    _ => AmsUnitType.unknown,
  };

  static MapEntry<int, AmsUnitType>? _parseModuleName(dynamic raw) {
    if (raw is! String) return null;
    final match = RegExp(
      r'^(ams|ams_f1|n3f|n3s)/(\d+)$',
    ).firstMatch(raw.trim().toLowerCase());
    if (match == null) return null;
    final id = int.tryParse(match.group(2)!);
    if (id == null) return null;
    final type = switch (match.group(1)) {
      'ams' => AmsUnitType.ams,
      'ams_f1' => AmsUnitType.amsLite,
      'n3f' => AmsUnitType.ams2Pro,
      'n3s' => AmsUnitType.amsHt,
      _ => AmsUnitType.unknown,
    };
    return MapEntry(id, type);
  }

  /// N3S / AMS HT 使用 128 起始的物理 ID，但存在位从 bit 4 连续排列。
  /// A2L 混接 AMS Lite（type=5）使用 bit 12 表示该单元存在。
  static int _existBitIndex(int id, {int? typeCode}) {
    if (typeCode == 5) return 12;
    return id >= 128 ? 4 + (id - 128) : id;
  }

  static int? _parseExtruderId(dynamic raw) {
    final value = _parseHex(raw);
    if (value == null) return null;
    final id = (value >> 8) & 0x0f;
    return id == 0 || id == 1 ? id : null;
  }

  static int? _parseInfoTypeCode(dynamic raw) {
    if (raw is int) return raw >= 0 ? raw & 0x0f : null;
    if (raw is! String) return null;
    var value = raw.trim().toLowerCase();
    if (value.startsWith('0x')) value = value.substring(2);
    if (value.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) return null;

    // 最后一个 hex 字符就是低四位，也避免超长标志串整数溢出。
    return int.tryParse(value.substring(value.length - 1), radix: 16);
  }

  static int? _parseHex(dynamic raw) {
    if (raw is int) return raw >= 0 ? raw : null;
    if (raw is! String) return null;
    var value = raw.trim().toLowerCase();
    if (value.startsWith('0x')) value = value.substring(2);
    if (value.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(value)) return null;
    return int.tryParse(value, radix: 16);
  }

  static int? _parseDecimalInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num && raw.isFinite && raw == raw.roundToDouble()) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }
}

class _AmsUnitEntry {
  final int fallbackId;
  final Map<String, dynamic> data;

  const _AmsUnitEntry({required this.fallbackId, required this.data});
}

String _normalizeAmsIdentity(String value) {
  final normalized = normalizeRfidTagUid(value);
  if (normalized.isEmpty || RegExp(r'^0+$').hasMatch(normalized)) return '';
  return normalized;
}

/// AMS 单个槽位的耗材信息。
///
/// 从顶层 `ams.ams[id].tray[slot]` 解析。空槽（无料）字段为空/null。
class AmsTray {
  /// AMS 编号（0, 1, 2...）
  final int amsId;

  /// 槽位编号（0-3）
  final int slot;

  /// 材质（PLA/PETG/ABS/TPU...，空槽为空字符串）
  final String trayType;

  /// 颜色 RGB hex（如 "F4D976FF"，末 2 位 alpha，空槽为空）
  final String trayColor;

  /// 剩余百分比 0-100（-1 表示无 RFID/未知）
  final int remain;

  /// 料盘总重（克，如 1000）
  final int trayWeight;

  /// 厂商/子品牌（Generic/Bambu...）
  final String traySubBrands;

  /// 料盘 SKU 索引（如 GFL99）
  final String trayInfoIdx;

  /// 是否有料（tray_exist_bits 对应位为 1）
  final bool hasFilament;

  /// Missing tray_exist_bits is unknown, never an authoritative removal.
  final bool hasFilamentObservation;

  /// A2L 混接模式的 AMS Lite。其物理 id 仍是 16，但槽位映射为
  /// 24..27（混接时用户让出任意一路，最多使用其中 3 路）。
  final bool mixedAmsLite;

  /// 耗材标签（"thirdparty" 表示第三方/无 RFID 耗材，空字符串表示拓竹原厂 RFID）。
  ///
  /// 用于识别用户自装的非拓竹耗材，此时 trayInfoIdx/trayColor 等字段可能为空或手动输入值。
  final String trayTag;

  /// 料盘 UUID（AMS 上报的 RFID 身份，用于精确追踪单卷）。
  ///
  /// 原厂料通常会提供该字段；支持 RFID 的第三方载体也可能提供 UUID。
  /// 该值只代表设备上报了一个身份，不代表标签已经通过 Bambu 签名校验。
  final String trayUuid;

  /// 物理 NFC 芯片 UID（AMS MQTT 的 `tag_uid`）。
  ///
  /// `trayUuid` 是逻辑耗材身份，官方料盘两面可能共用同一个逻辑 UUID；
  /// `tagUid` 才是 AMS 实际读到的 CUID/FUID 芯片身份。第三方耗材通常只
  /// 能提供后者，因此桌面端必须优先用它关联手机登记的 RFID 卷。
  final String tagUid;

  /// 喷嘴最低温度（℃，从 tray.nozzle_temp_min 解析）。
  ///
  /// 用于切片温度范围警告：当切片设置温度低于此值时提示用户。
  final int nozzleTempMin;

  /// 喷嘴最高温度（℃，从 tray.nozzle_temp_max 解析）。
  final int nozzleTempMax;

  /// 推荐干燥温度（℃，从 tray.drying_temp 解析）。
  final int dryingTemp;

  /// 推荐干燥时长（分钟，从 tray.drying_time 解析）。
  final int dryingTime;

  /// 剩余克数 = trayWeight × remain / 100。
  ///
  /// **Phase B 修复**：`remain == 0` 是合法耗尽状态，必须同步为 0；
  /// 只有 `remain < 0`（即 -1，未知/无 RFID）才视为无效值。
  /// hasFilament=false 时为 0。
  double get remainingGrams =>
      hasFilament && remain >= 0 ? trayWeight * remain / 100.0 : 0;

  /// RFID remain 是否为有效观测值（>= 0）。
  /// 0 = 耗尽；1-100 = 有效余量；-1 = 未知/无 RFID。
  bool get hasValidRemain => remain >= 0;

  /// 是否第三方耗材（trayTag == "thirdparty"）。
  bool get isThirdParty => trayTag == 'thirdparty';

  /// Canonical physical identity used by the desktop ↔ mobile binding chain.
  /// All-zero sentinels used by Bambu for an empty slot are ignored.
  String get normalizedTagUid => _normalizeAmsIdentity(tagUid);

  String get normalizedTrayUuid => _normalizeAmsIdentity(trayUuid);

  /// Prefer the physical chip UID. Fall back to the logical tray UUID for
  /// firmware/old telemetry that omits `tag_uid`.
  String get physicalRfidIdentity {
    final physical = normalizedTagUid;
    return physical.isNotEmpty ? physical : normalizedTrayUuid;
  }

  List<String> get rfidIdentityCandidates {
    final values = <String>[];
    for (final value in [normalizedTagUid, normalizedTrayUuid]) {
      if (value.isNotEmpty && !values.contains(value)) values.add(value);
    }
    return List.unmodifiable(values);
  }

  /// 是否有完整 RFID 信息（trayInfoIdx 非空且非第三方）。
  bool get hasRfidInfo => amsId >= 0 && trayInfoIdx.isNotEmpty && !isThirdParty;

  /// 是否有可供本地耗材库关联的 AMS RFID 身份。
  ///
  /// 这是比 [isBambuOfficialRfid] 更弱的事实判断：CUID/FUID 等第三方
  /// 载体被 AMS 上报时可能带有 `tray_uuid`，但 `tray_tag` 或品牌并不是
  /// Bambu。调用方必须继续按 UUID 查找已绑定的本地记录，不能凭此属性
  /// 自动创建或信任一条新耗材。
  bool get hasAmsRfidIdentity {
    if (amsId < 0) return false;
    // AMS uses all-zero values as the no-RFID sentinel. Treating either one as
    // a real identity would allow an empty/manual slot to enter RFID binding
    // or remaining-sync paths.
    return physicalRfidIdentity.isNotEmpty;
  }

  /// 只有设备明确上报拓竹品牌时，才允许进入原厂 RFID 自动流程。
  bool get isBambuOfficialRfid {
    if (!hasRfidInfo || !hasAmsRfidIdentity) return false;
    final brand = traySubBrands.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff]'),
      '',
    );
    return brand == 'bambu' ||
        brand == 'bambulab' ||
        brand == 'bbl' ||
        brand == '拓竹';
  }

  /// 全局槽位索引。AMS HT 的物理 ID 从 128 开始、槽位索引从 16 开始。
  int get globalSlot {
    if (amsId < 0) return slot;
    if (mixedAmsLite) return 24 + slot;
    return amsId >= 128 ? 16 + (amsId - 128) + slot : amsId * 4 + slot;
  }

  /// project_file.ams_mapping 的编号。HT 的位掩码/本地通道在 16..23，
  /// 发送编号却是物理 AMS ID 128..135。不能直接发送 globalSlot。
  int get protocolTrayId => amsId >= 128 ? amsId : globalSlot;

  const AmsTray({
    required this.amsId,
    required this.slot,
    this.trayType = '',
    this.trayColor = '',
    this.remain = -1,
    this.trayWeight = 0,
    this.traySubBrands = '',
    this.trayInfoIdx = '',
    this.hasFilament = false,
    this.hasFilamentObservation = true,
    this.mixedAmsLite = false,
    this.trayTag = '',
    this.trayUuid = '',
    this.tagUid = '',
    this.nozzleTempMin = 0,
    this.nozzleTempMax = 0,
    this.dryingTemp = 0,
    this.dryingTime = 0,
  });

  /// Parses external-spool metadata. IDs 255/254 map to right/single and left
  /// external inputs, but remain non-AMS so they can never be treated as RFID.
  factory AmsTray.fromVirtual(
    Map<String, dynamic> tray, {
    required int fallbackSlot,
  }) {
    final rawId = _parseInt(tray['id']);
    final slot = switch (rawId) {
      254 => 1,
      255 => 0,
      _ => fallbackSlot,
    };
    return AmsTray(
      amsId: -1,
      slot: slot,
      trayType: tray['tray_type'] as String? ?? '',
      trayColor: tray['tray_color'] as String? ?? '',
      remain: _parseInt(tray['remain']) ?? -1,
      trayWeight: _parseInt(tray['tray_weight']) ?? 0,
      traySubBrands: tray['tray_sub_brands'] as String? ?? '',
      trayInfoIdx: tray['tray_info_idx'] as String? ?? '',
      hasFilament: false,
      trayTag: 'external',
      trayUuid: '',
      tagUid: '',
      nozzleTempMin: _parseInt(tray['nozzle_temp_min']) ?? 0,
      nozzleTempMax: _parseInt(tray['nozzle_temp_max']) ?? 0,
      dryingTemp: _parseInt(tray['drying_temp']) ?? 0,
      dryingTime: _parseInt(tray['drying_time']) ?? 0,
    );
  }

  /// 从顶层 ams 节点解析所有槽位。
  ///
  /// ams 节点结构：
  /// ```json
  /// {"ams": {"ams_exist_bits":"1", "tray_exist_bits":"f",
  ///   "ams": [{"id":"0", "tray":[{"id":"0","tray_type":"PLA",...}, ...]}]}}
  /// ```
  ///
  /// 返回的列表按 amsId × 4 + slot 顺序排列。
  /// ams_exist_bits 位掩码可在外部通过 [parseAmsExistBits] 获取。
  static List<AmsTray> parseList(Map<String, dynamic> amsData) {
    return AmsUnit.parseList(amsData)
        .where((unit) => unit.isPresent)
        .expand((unit) => unit.trays)
        .toList(growable: false);
  }

  static List<AmsTray> _parseUnitTrays(
    Map<String, dynamic> amsEntry, {
    required int amsId,
    bool mixedAmsLite = false,
    required int? trayExistBits,
  }) {
    final result = <AmsTray>[];
    final trays = amsEntry['tray'];
    if (trays is! List) return result;

    for (var slotIdx = 0; slotIdx < trays.length; slotIdx++) {
      final rawTray = trays[slotIdx];
      if (rawTray is! Map) continue;
      final tray = Map<String, dynamic>.from(rawTray);

      // tray 数组可以稀疏或重排，id 才是物理槽位，数组下标不是。
      final slot = _parseInt(tray['id']) ?? slotIdx;
      if (slot < 0 || slot > 3 || (amsId >= 128 && slot != 0)) continue;

      final globalSlot = mixedAmsLite
          ? 24 + slot
          : amsId >= 128
          ? 16 + (amsId - 128) + slot
          : amsId * 4 + slot;
      final hasFilament =
          trayExistBits != null && (trayExistBits & (1 << globalSlot)) != 0;

      result.add(
        AmsTray(
          amsId: amsId,
          slot: slot,
          trayType: tray['tray_type'] as String? ?? '',
          trayColor: tray['tray_color'] as String? ?? '',
          remain: _parseInt(tray['remain']) ?? -1,
          trayWeight: _parseInt(tray['tray_weight']) ?? 0,
          traySubBrands: tray['tray_sub_brands'] as String? ?? '',
          trayInfoIdx: tray['tray_info_idx'] as String? ?? '',
          hasFilament: hasFilament,
          hasFilamentObservation: trayExistBits != null,
          mixedAmsLite: mixedAmsLite,
          trayTag: tray['tray_tag'] as String? ?? '',
          trayUuid: tray['tray_uuid'] as String? ?? '',
          tagUid: (tray['tag_uid'] ?? tray['tagUid'])?.toString() ?? '',
          nozzleTempMin: _parseInt(tray['nozzle_temp_min']) ?? 0,
          nozzleTempMax: _parseInt(tray['nozzle_temp_max']) ?? 0,
          dryingTemp: _parseInt(tray['drying_temp']) ?? 0,
          dryingTime: _parseInt(tray['drying_time']) ?? 0,
        ),
      );
    }
    return result;
  }

  /// 解析 ams_exist_bits 位掩码，返回各 AMS 单元是否物理连接。
  ///
  /// 拓竹协议中 `ams_exist_bits` 是 hex 字符串（如 "3" = 0b11 = AMS0+AMS1 都存在）。
  /// 用于多 AMS 场景判断哪些槽位是真实存在的，避免显示不存在的 AMS 槽位。
  static List<bool> parseAmsExistBits(Map<String, dynamic> amsData) {
    final bits = _parseBitmask(amsData['ams_exist_bits']);
    // 默认最多支持 4 个 AMS 单元（16 槽位），足够覆盖 X1C 双 AMS + 扩展
    return [for (int i = 0; i < 4; i++) (bits & (1 << i)) != 0];
  }

  /// 解析 hex 位掩码字符串（如 "f" → 15, "ff" → 255）
  static int _parseBitmask(dynamic hex) => AmsUnit._parseHex(hex) ?? 0;

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// 打印机连接模式。
enum BambuConnectionMode { lan, cloud }

/// 打印机连接配置。持久化到 shared_preferences。
class PrinterConnectionConfig {
  /// 打印机序列号（拓竹设备 SN）
  final String serial;

  /// 打印机 IP 地址（局域网，仅 LAN 模式用）
  final String host;

  /// LAN Access Code（仅 LAN 模式用）
  final String accessCode;

  /// 端口（默认 8883 TLS）
  final int port;

  /// 连接模式
  final BambuConnectionMode mode;

  /// 设备产品名（如 "P1S"，仅 Cloud 模式用于 UI）
  final String? devProductName;

  /// 用户给打印机起的名字（仅 Cloud 模式）
  final String? displayName;

  /// 当前安装的喷嘴直径（mm）。
  ///
  /// 只有云 API 明确返回或用户明确选择时才有值；未知时保持 null，
  /// 调度器不得用 0.4mm 默认值冒充硬件事实。
  final double? installedNozzleDiameter;

  const PrinterConnectionConfig({
    required this.serial,
    required this.host,
    required this.accessCode,
    this.port = 8883,
    this.mode = BambuConnectionMode.lan,
    this.devProductName,
    this.displayName,
    this.installedNozzleDiameter,
  });

  factory PrinterConnectionConfig.cloud({
    required String serial,
    @Deprecated('云端配置不使用 LAN Access Code') String? accessCode,
    String? devProductName,
    String? displayName,
    double? installedNozzleDiameter,
  }) {
    // Keep the legacy named argument source-compatible, but deliberately do
    // not copy it into a cloud config. LAN credentials belong to a separate
    // PrinterConnectionConfig.lan instance.
    return PrinterConnectionConfig(
      serial: serial,
      host: '',
      accessCode: '',
      mode: BambuConnectionMode.cloud,
      devProductName: devProductName,
      displayName: displayName,
      installedNozzleDiameter: installedNozzleDiameter,
    );
  }

  /// 创建独立的 LAN 连接配置。
  ///
  /// 调用方可以把云 API 返回的 access code 作为预填值传入，但该对象
  /// 只属于 LAN 链路，永远不会被云 MQTT/云摄像头读取。
  factory PrinterConnectionConfig.lan({
    required String serial,
    required String host,
    required String accessCode,
    int port = 8883,
    String? devProductName,
    String? displayName,
    double? installedNozzleDiameter,
  }) {
    return PrinterConnectionConfig(
      serial: serial,
      host: host,
      accessCode: accessCode,
      port: port,
      mode: BambuConnectionMode.lan,
      devProductName: devProductName,
      displayName: displayName,
      installedNozzleDiameter: installedNozzleDiameter,
    );
  }

  String get displayLabel => displayName?.isNotEmpty == true
      ? displayName!
      : (devProductName?.isNotEmpty == true ? devProductName! : serial);

  Map<String, dynamic> toJson() => {
    'serial': serial,
    'host': host,
    'accessCode': accessCode,
    'port': port,
    'mode': mode.name,
    if (devProductName != null) 'devProductName': devProductName,
    if (displayName != null) 'displayName': displayName,
    if (installedNozzleDiameter != null)
      'installedNozzleDiameter': installedNozzleDiameter,
  };

  factory PrinterConnectionConfig.fromJson(Map<String, dynamic> json) {
    final modeStr = json['mode'] as String? ?? 'lan';
    return PrinterConnectionConfig(
      serial: json['serial'] as String,
      host: json['host'] as String? ?? '',
      accessCode: json['accessCode'] as String? ?? '',
      port: json['port'] as int? ?? 8883,
      mode: modeStr == 'cloud'
          ? BambuConnectionMode.cloud
          : BambuConnectionMode.lan,
      devProductName: json['devProductName'] as String?,
      displayName: json['displayName'] as String?,
      installedNozzleDiameter: (json['installedNozzleDiameter'] as num?)
          ?.toDouble(),
    );
  }
}
