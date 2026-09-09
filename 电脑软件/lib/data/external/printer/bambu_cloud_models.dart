import 'dart:convert';

/// 拓竹云账号区域。
///
/// 拓竹在 中国 / 海外 使用两套独立的 API 和 MQTT 域名。
/// 用户注册拓竹账号时选的区域决定走哪套。
enum BambuRegion {
  /// 中国区（api.bambulab.cn / cn.mqtt.bambulab.com）
  china('China', 'api.bambulab.cn', 'cn.mqtt.bambulab.com'),

  /// 海外区（api.bambulab.com / us.mqtt.bambulab.com）
  overseas('Overseas', 'api.bambulab.com', 'us.mqtt.bambulab.com');

  /// 拓竹协议里的 region 标识（用于登录接口等）
  final String code;

  /// HTTP API 域名（不含协议头）
  final String apiHost;

  /// 云 MQTT broker 域名
  final String mqttHost;

  const BambuRegion(this.code, this.apiHost, this.mqttHost);

  /// HTTP API 基址（含 https://）
  String get apiBaseUrl => 'https://$apiHost';

  /// 登录接口完整 URL
  String get loginUrl => '$apiBaseUrl/v1/user-service/user/login';

  /// 设备绑定列表接口完整 URL
  String get bindUrl => '$apiBaseUrl/v1/iot-service/api/user/bind';

  /// 任务历史接口完整 URL
  String get tasksUrl => '$apiBaseUrl/v1/user-service/my/tasks';
}

/// 拓竹云账号会话。
///
/// 登录成功后拿到 accessToken（JWT）+ username（形如 u_123456789）。
/// 这两个值用于后续所有 API 请求的 Bearer 鉴权，以及云 MQTT 的用户名/密码。
///
/// 字段含义参考 pybambu 逆向协议：
/// - accessToken：JWT，第二段 base64 解码后含 username 字段
/// - username：从 JWT 解析，形如 "u_<digits>"，用作云 MQTT 的 username
class BambuCloudSession {
  /// 区域
  final BambuRegion region;

  /// 用户邮箱（登录用）
  final String email;

  /// JWT access token（云 API 鉴权 + 云 MQTT 密码）
  final String accessToken;

  /// 从 JWT 解析出的用户名，形如 "u_123456789"（云 MQTT 用户名）
  final String username;

  /// 登录时间（用于判断 token 是否需要刷新）
  final DateTime loginAt;

  /// 登录接口返回的刷新令牌。部分区域/账号可能不返回。
  final String? refreshToken;

  /// 服务端声明的 access token 过期时间。
  final DateTime? expiresAt;

  /// 服务端声明的 refresh token 过期时间。
  final DateTime? refreshExpiresAt;

  const BambuCloudSession({
    required this.region,
    required this.email,
    required this.accessToken,
    required this.username,
    required this.loginAt,
    this.refreshToken,
    this.expiresAt,
    this.refreshExpiresAt,
  });

  /// 服务端过期时间优先；旧数据尝试读取 JWT 的 exp。
  /// opaque token 无法本地判断时返回 null，由服务端 401 作为最终依据。
  DateTime? get effectiveExpiresAt => expiresAt ?? _jwtExpiresAt(accessToken);

  bool get isExpired {
    final expiry = effectiveExpiresAt;
    if (expiry == null) return false;
    return !DateTime.now().isBefore(expiry);
  }

  Map<String, dynamic> toJson() => {
        'region': region.code,
        'email': email,
        'accessToken': accessToken,
        'username': username,
        'loginAt': loginAt.toIso8601String(),
        if (refreshToken != null && refreshToken!.isNotEmpty)
          'refreshToken': refreshToken,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (refreshExpiresAt != null)
          'refreshExpiresAt': refreshExpiresAt!.toIso8601String(),
      };

  factory BambuCloudSession.fromJson(Map<String, dynamic> json) {
    final regionCode = json['region'] as String? ?? 'China';
    return BambuCloudSession(
      region:
          regionCode == 'Overseas' ? BambuRegion.overseas : BambuRegion.china,
      email: json['email'] as String,
      accessToken: json['accessToken'] as String,
      username: json['username'] as String,
      loginAt: _parseDateTime(json['loginAt']),
      refreshToken: json['refreshToken'] as String?,
      expiresAt: _tryParseDateTime(json['expiresAt']),
      refreshExpiresAt: _tryParseDateTime(json['refreshExpiresAt']),
    );
  }
}

DateTime? _jwtExpiresAt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final json = jsonDecode(payload);
    if (json is! Map<String, dynamic>) return null;
    final exp = json['exp'];
    final seconds = exp is num ? exp.toInt() : int.tryParse('$exp');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
        .toLocal();
  } catch (_) {
    return null;
  }
}

DateTime? _tryParseDateTime(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

/// 容错解析 DateTime：解析失败回退到当前时间，避免旧数据损坏导致
/// 整个 session 列表加载失败（连锁影响登录态恢复）。
DateTime _parseDateTime(dynamic value) {
  if (value is! String) return DateTime.now();
  try {
    return DateTime.parse(value);
  } catch (_) {
    return DateTime.now();
  }
}

/// 云端设备信息（设备绑定列表里的一项）。
///
/// 登录后从 /v1/iot-service/api/user/bind 拉取。
/// 每台绑定到账号的打印机一条记录，含序列号、名称、在线状态、access code 等。
class BambuCloudDevice {
  /// 打印机序列号（dev_id），即 LAN 模式里的 serial
  final String devId;

  /// 用户给打印机起的名字（如 "Bambu P1S"）
  final String name;

  /// 是否在线
  final bool online;

  /// 打印状态（拓竹返回的字符串，如 "RUNNING" / "SUCCESS"）
  final String printStatus;

  /// 设备型号代号（如 "C12"，内部代号）
  final String devModelName;

  /// 设备产品名（如 "P1S" / "X1 Carbon"）
  final String devProductName;

  /// 云 API 返回的 LAN Access Code（11 位字母数字）。
  /// 仅在用户明确创建独立 LAN 配置时使用；云端连接和云端摄像头绝不读取它。
  final String devAccessCode;

  /// 喷嘴直径（mm）
  final double? nozzleDiameter;

  /// 固件版本号（如 "01.09.05.01"）
  final String swVer;

  /// 硬件版本号
  final String hwVer;

  /// 各模块固件版本（key 为模块名如 "ota"/"mc"/"th"/"ams"，value 为版本号）
  final Map<String, String>? moduleVersions;

  /// 设备 OEM 类型（从 device_oem_type 解析，区分代工/自有型号）
  final String? deviceOemType;

  const BambuCloudDevice({
    required this.devId,
    required this.name,
    required this.online,
    required this.printStatus,
    required this.devModelName,
    required this.devProductName,
    required this.devAccessCode,
    required this.nozzleDiameter,
    this.swVer = '',
    this.hwVer = '',
    this.moduleVersions,
    this.deviceOemType,
  });

  BambuCloudDevice copyWith({
    String? devId,
    String? name,
    bool? online,
    String? printStatus,
    String? devModelName,
    String? devProductName,
    String? devAccessCode,
    double? nozzleDiameter,
    String? swVer,
    String? hwVer,
    Map<String, String>? moduleVersions,
    String? deviceOemType,
  }) {
    return BambuCloudDevice(
      devId: devId ?? this.devId,
      name: name ?? this.name,
      online: online ?? this.online,
      printStatus: printStatus ?? this.printStatus,
      devModelName: devModelName ?? this.devModelName,
      devProductName: devProductName ?? this.devProductName,
      devAccessCode: devAccessCode ?? this.devAccessCode,
      nozzleDiameter: nozzleDiameter ?? this.nozzleDiameter,
      swVer: swVer ?? this.swVer,
      hwVer: hwVer ?? this.hwVer,
      moduleVersions: moduleVersions ?? this.moduleVersions,
      deviceOemType: deviceOemType ?? this.deviceOemType,
    );
  }

  factory BambuCloudDevice.fromJson(Map<String, dynamic> json) {
    return BambuCloudDevice(
      devId: json['dev_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      online: json['online'] as bool? ?? false,
      printStatus: json['print_status'] as String? ?? '',
      devModelName: json['dev_model_name'] as String? ?? '',
      devProductName: json['dev_product_name'] as String? ?? '',
      devAccessCode: json['dev_access_code'] as String? ?? '',
      nozzleDiameter: (json['nozzle_diameter'] as num?)?.toDouble(),
      swVer: json['sw_ver'] as String? ?? '',
      hwVer: json['hw_ver'] as String? ?? '',
      moduleVersions: _parseModuleVersions(json['module_versions']),
      deviceOemType: json['device_oem_type'] as String?,
    );
  }

  /// 解析 module_versions 节点（可能是 Map<String, dynamic>）
  static Map<String, String>? _parseModuleVersions(dynamic v) {
    if (v is! Map) return null;
    final result = <String, String>{};
    v.forEach((key, value) {
      if (key is String && value != null) {
        result[key] = value.toString();
      }
    });
    return result.isEmpty ? null : result;
  }

  /// 简化的设备类型标识（P1S / X1C 等）。
  /// "X1 Carbon" → "X1C"，其他去空格。
  String get deviceType {
    if (devProductName == 'X1 Carbon') return 'X1C';
    return devProductName.replaceAll(' ', '');
  }
}

/// 拓竹云端远程摄像头的 P2P 临时凭据。
///
/// 由 `/v1/iot-service/api/user/ttcode` 返回，仅用于当前账号拥有的设备。
/// 实际视频由 Bambu Studio 的 BambuSource 网络组件通过 TUTK/Agora 建立，
/// 本软件不会把这些凭据下发给客户浏览器。
class BambuCloudCameraCredentials {
  const BambuCloudCameraCredentials({
    required this.uid,
    required this.authKey,
    required this.password,
    required this.region,
    required this.type,
  });

  final String uid;
  final String authKey;
  final String password;
  final String region;
  final String type;

  factory BambuCloudCameraCredentials.fromJson(Map<String, dynamic> json) {
    return BambuCloudCameraCredentials(
      uid: json['ttcode'] as String? ?? '',
      authKey: json['authkey'] as String? ?? '',
      password: json['passwd'] as String? ?? '',
      region: json['region'] as String? ?? '',
      type: json['type'] as String? ?? 'tutk',
    );
  }

  bool get isComplete =>
      uid.isNotEmpty && authKey.isNotEmpty && password.isNotEmpty;
}

/// 云端打印任务历史（/v1/user-service/my/tasks 返回的单条记录）。
///
/// 比切片缓存更权威：是打印机实际上报的真实打印数据。
/// 含实际耗材克数、长度、耗时、AMS 颜色映射等。
class BambuCloudTask {
  final int id;
  final String title;
  final String status; // 拓竹返回的状态码，如 "4" 表示完成
  final DateTime? startTime;
  final DateTime? endTime;
  final double weight; // 克
  final int length; // 毫米
  final int costTime; // 秒
  final String deviceId;
  final String deviceModel;
  final String deviceName;
  final List<BambuCloudTaskFilament> amsFilaments;

  const BambuCloudTask({
    required this.id,
    required this.title,
    required this.status,
    this.startTime,
    this.endTime,
    required this.weight,
    required this.length,
    required this.costTime,
    required this.deviceId,
    required this.deviceModel,
    required this.deviceName,
    required this.amsFilaments,
  });

  factory BambuCloudTask.fromJson(Map<String, dynamic> json) {
    final amsList = json['amsDetailMapping'] as List<dynamic>? ?? [];
    return BambuCloudTask(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      status: json['status']?.toString() ?? '',
      startTime: _parseTime(json['startTime']),
      endTime: _parseTime(json['endTime']),
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
      length: (json['length'] as num?)?.toInt() ?? 0,
      costTime: (json['costTime'] as num?)?.toInt() ?? 0,
      deviceId: json['deviceId'] as String? ?? '',
      deviceModel: json['deviceModel'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? '',
      amsFilaments: amsList
          .map(
            (e) => BambuCloudTaskFilament.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  static DateTime? _parseTime(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
}

/// 云端任务里的单色耗材明细。
class BambuCloudTaskFilament {
  /// AMS 槽位号
  final int ams;

  /// HEX 颜色（如 "F4D976FF"，8位含 alpha）
  final String sourceColor;

  /// 耗材 SKU（如 "GFL99"）
  final String filamentId;

  /// 耗材类型（如 "PLA"）
  final String filamentType;

  /// 该色实际耗材克数
  final double weight;

  const BambuCloudTaskFilament({
    required this.ams,
    required this.sourceColor,
    required this.filamentId,
    required this.filamentType,
    required this.weight,
  });

  factory BambuCloudTaskFilament.fromJson(Map<String, dynamic> json) {
    return BambuCloudTaskFilament(
      ams: (json['ams'] as num?)?.toInt() ?? 0,
      sourceColor: json['sourceColor'] as String? ?? '',
      filamentId: json['filamentId'] as String? ?? '',
      filamentType: json['filamentType'] as String? ?? '',
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
    );
  }
}
