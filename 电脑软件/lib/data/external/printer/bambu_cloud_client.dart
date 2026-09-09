import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, min;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'bambu_cloud_models.dart';

/// 拓竹云 API 错误分类。
///
/// 用于上层（[BambuCloudNotifier]）针对性处理：
/// - [authentication] → 清 session + 提示用户重新登录
/// - [network] / [server] / [rateLimit] → 提示稍后重试（可自动重试）
/// - [protocol] → 提示协议变更，可能需要更新应用
enum BambuCloudErrorCategory {
  /// 认证失败（401），需要重新登录
  authentication,

  /// 权限不足（403），可能被 Cloudflare 拦截
  permission,

  /// 接口不存在（404），拓竹协议变更
  protocol,

  /// 请求过频（429），需等待
  rateLimit,

  /// 网络/超时错误
  network,

  /// 拓竹服务器错误（5xx）
  server,

  /// 客户端错误（其他 4xx）
  client,

  /// 未知
  unknown,
}

/// 拓竹云客户端版本号（集中管理）。
///
/// 这些值通过抓包 BambuStudio / OrcaSlicer 获得，拓竹更新协议时
/// 可能需要同步修改。集中到这里避免散落在多个 header 构造点。
class BambuClientVersion {
  /// OrcaSlicer 模拟版本（用于登录/设备列表/任务历史接口）
  static const orcaSlicer = '01.09.05.51';

  /// BambuStudio 模拟版本（用于上传预设/解绑设备接口）
  ///
  /// 默认值在 [defaultBambuStudio] 上；可通过 [bambuStudio] getter 读取
  /// 用户在设置页覆盖的值。拓竹更新协议导致 401 时，用户可自改无需等版本更新。
  static const defaultBambuStudio = '02.07.01.57';

  /// 用户覆盖的 BambuStudio 版本号（null 表示用默认值）。
  static String? _bambuStudioOverride;

  /// 获取当前生效的 BambuStudio 版本号（用户覆盖优先）。
  static String get bambuStudio => _bambuStudioOverride ?? defaultBambuStudio;

  /// 设置/清除用户覆盖的 BambuStudio 版本号。
  /// 传 null 清除覆盖，恢复默认值。
  static void setBambuStudioOverride(String? value) {
    _bambuStudioOverride = (value == null || value.isEmpty) ? null : value;
  }

  /// bambu_network_agent 版本（OrcaSlicer 系列 User-Agent）
  static const networkAgentOrca = '01.09.05.01';

  /// bambu_network_agent 版本（BambuStudio 系列 User-Agent）
  static const defaultNetworkAgentStudio = '02.07.01.51';

  /// 用户覆盖的 bambu_network_agent 版本（BambuStudio 系列）。
  static String? _networkAgentStudioOverride;

  /// 获取当前生效的 bambu_network_agent 版本（BambuStudio 系列）。
  static String get networkAgentStudio =>
      _networkAgentStudioOverride ?? defaultNetworkAgentStudio;

  /// 设置/清除用户覆盖的 bambu_network_agent 版本（BambuStudio 系列）。
  static void setNetworkAgentStudioOverride(String? value) {
    _networkAgentStudioOverride =
        (value == null || value.isEmpty) ? null : value;
  }
}

/// 拓竹云客户端。
///
/// 通过逆向 BambuStudio / 手机 APP 的登录协议，用账号密码换取 accessToken，
/// 然后用 token 调用云端 API（设备列表、任务历史）+ 连接云 MQTT。
///
/// **认证流程**（参考 pybambu bambu_cloud.py）：
///
/// 多数账号（含中国区手机号）需要**验证码登录**，流程分三步：
/// 1. POST /v1/user-service/user/login  body: {account, password}
///    → 返回 {loginType:"verifyCode"} 表示需要验证码
/// 2. POST /v1/user-service/user/sendsmscode 或 sendemail/code
///    body: {phone/email, type:"codeLogin"} → 发送验证码到手机/邮箱
/// 3. POST /v1/user-service/user/login  body: {account, code}
///    → 返回 {accessToken:"JWT..."}
///
/// 少数账号可直接密码登录（第一步就返回 token）。
///
/// **JWT 解析**：第二段 base64 解码 → 取 username 字段（形如 "u_123456789"）
///
/// **云 MQTT 连接**（协议与 LAN MQTT 完全相同）：
/// - host: region.mqttHost（cn.mqtt.bambulab.com / us.mqtt.bambulab.com）
/// - port: 8883 (TLS)
/// - username: session.username（u_xxx）
/// - password: session.accessToken（JWT）
///
/// **风险提示**：这是逆向协议，拓竹可能随时改接口。
class BambuCloudClient {
  static const _timeout = Duration(seconds: 15);

  // Bambu's device-security assertion is a rotating authentication
  // credential. It must never be accepted from environment variables or
  // persisted by this application. The official networking component owns
  // any authorization needed by a supported camera session.
  static String? get _deviceSecuritySign => null;

  /// BBL 客户端请求头。模拟 OrcaSlicer/BambuStudio 的请求特征，
  /// 部分接口（如 sendsmscode）需要这些 header 才不被 Cloudflare 拦截。
  ///
  /// 版本号集中管理在 [BambuClientVersion]，拓竹更新协议时统一修改。
  static Map<String, String> get _bblHeaders => {
        'User-Agent':
            'bambu_network_agent/${BambuClientVersion.networkAgentOrca}',
        'X-BBL-Client-Name': 'OrcaSlicer',
        'X-BBL-Client-Type': 'slicer',
        'X-BBL-Client-Version': BambuClientVersion.orcaSlicer,
        'X-BBL-Language': 'zh-CN',
        'X-BBL-OS-Type': 'windows',
        'X-BBL-OS-Version': '10.0',
        'X-BBL-Agent-Version': BambuClientVersion.networkAgentOrca,
        'X-BBL-Executable-info': '{}',
        'X-BBL-Agent-OS-Type': 'windows',
        'accept': 'application/json',
        'Content-Type': 'application/json',
      };

  /// 第一步：用密码登录。
  ///
  /// 多数账号会返回 [LoginResult.needsCode]（需要验证码）。
  /// 少数账号直接返回 [LoginResult.success]（拿到 token）。
  static Future<LoginResult> loginWithPassword({
    required BambuRegion region,
    required String account,
    required String password,
  }) async {
    if (account.isEmpty || password.isEmpty) {
      throw const BambuCloudException(
        '账号和密码不能为空',
        category: BambuCloudErrorCategory.client,
      );
    }

    final response = await http
        .post(
          Uri.parse(region.loginUrl),
          headers: _bblHeaders,
          body: jsonEncode({'account': account, 'password': password}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final accessToken = json['accessToken'] as String? ?? '';

    // 直接拿到 token（少数账号）
    if (accessToken.isNotEmpty) {
      final username =
          await _resolveUsername(token: accessToken, region: region);
      return LoginResult.success(
        _sessionFromLoginResponse(
          json: json,
          region: region,
          account: account,
          accessToken: accessToken,
          username: username,
        ),
      );
    }

    // 需要验证码
    final loginType = json['loginType'] as String? ?? '';
    if (loginType == 'verifyCode') {
      return const LoginResult.needsCode();
    }

    // 其他异常
    final msg = json['message'] as String? ?? '登录失败（$loginType）';
    throw BambuCloudException(
      msg,
      category: BambuCloudErrorCategory.client,
      statusCode: 200,
    );
  }

  /// 第二步：发送验证码。
  ///
  /// 中国区手机号 → SMS 短信；海外区邮箱 → 邮件验证码。
  /// 接口有 Cloudflare 防护，必须带 BBL 客户端 headers。
  static Future<void> sendVerificationCode({
    required BambuRegion region,
    required String account,
  }) async {
    final isEmail = account.contains('@');
    final url = isEmail
        ? 'https://api.bambulab.com/v1/user-service/user/sendemail/code'
        : '${region.apiBaseUrl}/v1/user-service/user/sendsmscode';
    final body = isEmail
        ? {'email': account, 'type': 'codeLogin'}
        : {'phone': account, 'type': 'codeLogin'};

    final response = await http
        .post(
          Uri.parse(url),
          headers: _bblHeaders,
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }
  }

  /// 第三步：用验证码换 token。
  static Future<BambuCloudSession> loginWithCode({
    required BambuRegion region,
    required String account,
    required String code,
  }) async {
    final response = await http
        .post(
          Uri.parse(region.loginUrl),
          headers: _bblHeaders,
          body: jsonEncode({'account': account, 'code': code}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      final body = response.body;
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        final code = j['code'];
        if (code == 1) {
          throw const BambuCloudException(
            '验证码已过期，请重新获取',
            category: BambuCloudErrorCategory.client,
          );
        } else if (code == 2) {
          throw const BambuCloudException(
            '验证码错误',
            category: BambuCloudErrorCategory.client,
          );
        }
      } catch (e) {
        if (e is BambuCloudException) rethrow;
      }
      throw _formatHttpError(response.statusCode, body);
    }

    final json = _parseJsonResponse(response);
    final accessToken = json['accessToken'] as String? ?? '';
    if (accessToken.isEmpty) {
      throw const BambuCloudException(
        '验证码登录失败（未返回 token）',
        category: BambuCloudErrorCategory.protocol,
      );
    }

    final username = await _resolveUsername(token: accessToken, region: region);
    return _sessionFromLoginResponse(
      json: json,
      region: region,
      account: account,
      accessToken: accessToken,
      username: username,
    );
  }

  static BambuCloudSession _sessionFromLoginResponse({
    required Map<String, dynamic> json,
    required BambuRegion region,
    required String account,
    required String accessToken,
    required String username,
  }) {
    final now = DateTime.now();
    DateTime? expiresAfter(dynamic value) {
      final seconds = value is num ? value.toInt() : int.tryParse('$value');
      if (seconds == null || seconds <= 0) return null;
      return now.add(Duration(seconds: seconds));
    }

    final refreshToken = json['refreshToken'] as String?;
    return BambuCloudSession(
      region: region,
      email: account,
      accessToken: accessToken,
      username: username,
      loginAt: now,
      refreshToken:
          refreshToken == null || refreshToken.isEmpty ? null : refreshToken,
      expiresAt: expiresAfter(json['expiresIn']),
      refreshExpiresAt: expiresAfter(json['refreshExpiresIn']),
    );
  }

  /// 拉取账号下绑定的所有打印机列表。
  ///
  /// 幂等 GET 接口，网络/服务器错误时自动重试 1 次。
  static Future<List<BambuCloudDevice>> getDeviceList(
    BambuCloudSession session,
  ) async {
    final response = await _requestWithRetry(
      () => http.get(
        Uri.parse(session.region.bindUrl),
        headers: {
          ..._bblHeaders,
          'Authorization': 'Bearer ${session.accessToken}',
        },
      ).timeout(_timeout),
    );

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final devices = json['devices'] as List<dynamic>? ?? [];
    // 调试日志：打印每个设备返回的 JSON 字段名（用于排查固件版本等字段缺失问题）
    for (final d in devices) {
      if (d is Map<String, dynamic>) {
        debugPrint('[BambuCloud] 设备 ${d['dev_id']} 字段: ${d.keys.toList()}');
        debugPrint('  sw_ver=${d['sw_ver']}, hw_ver=${d['hw_ver']}, '
            'module_versions=${d['module_versions'] != null ? '有' : '无'}');
      }
    }
    return devices
        .map((e) => BambuCloudDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取云端打印机的远程摄像头 P2P 临时凭据。
  ///
  /// 该接口返回 TUTK UID、授权键和临时密码；视频本身不是 HTTP 地址，
  /// 仍需交给 Bambu Studio 安装的 BambuSource 网络组件建立 P2P 连接。
  static Future<BambuCloudCameraCredentials> getCameraCredentials(
    BambuCloudSession session,
    String deviceId, {
    String? firmwareVersion,
  }) async {
    if (deviceId.trim().isEmpty) {
      throw const BambuCloudException(
        '设备序列号为空，无法获取远程摄像头凭据',
        category: BambuCloudErrorCategory.client,
      );
    }
    final url = '${session.region.apiBaseUrl}/v1/iot-service/api/user/ttcode';
    final deviceVersion = firmwareVersion?.trim().isNotEmpty == true
        ? firmwareVersion!.trim()
        : '01.08.01.00';
    final body = jsonEncode({
      'dev_id': deviceId,
      'dev_version': deviceVersion,
      'protocols': const ['tutk'],
    });

    Future<http.Response> request({required bool includeSecuritySign}) {
      final headers = _bambuStudioHeaders(
        session.accessToken,
        session.username,
      );
      final securitySign = _deviceSecuritySign;
      if (includeSecuritySign && securitySign != null) {
        headers['x-bbl-device-security-sign'] = securitySign;
      }
      return http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(_timeout);
    }

    final response = await request(includeSecuritySign: false);
    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }
    final json = _parseJsonResponse(response);
    final credentials = BambuCloudCameraCredentials.fromJson(json);
    if (!credentials.isComplete) {
      throw BambuCloudException(
        '拓竹云端没有返回可用的远程摄像头凭据：${json['message'] ?? json['error'] ?? '未知响应'}',
        category: BambuCloudErrorCategory.protocol,
        statusCode: response.statusCode,
      );
    }
    return credentials;
  }

  /// 拉取打印任务历史。
  ///
  /// 幂等 GET 接口，网络/服务器错误时自动重试 1 次。
  static Future<List<BambuCloudTask>> getTaskList(
    BambuCloudSession session, {
    String? deviceId,
  }) async {
    final response = await _requestWithRetry(
      () => http.get(
        Uri.parse(session.region.tasksUrl),
        headers: {
          ..._bblHeaders,
          'Authorization': 'Bearer ${session.accessToken}',
        },
      ).timeout(_timeout),
    );

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final hits = json['hits'] as List<dynamic>? ?? [];
    var tasks = hits
        .map((e) => BambuCloudTask.fromJson(e as Map<String, dynamic>))
        .toList();
    if (deviceId != null) {
      tasks = tasks.where((t) => t.deviceId == deviceId).toList();
    }
    return tasks;
  }

  /// 对已有 session 重新解析 username（用于修复旧版保存的错误 session）。
  static Future<String> resolveUsernameForSession(BambuCloudSession session) {
    return _resolveUsername(token: session.accessToken, region: session.region);
  }

  /// 从 token 解析 username（用于 MQTT 连接）。
  ///
  /// 拓竹中国区返回 opaque token（非 JWT，如 "AQAlMW0Bbd_0RSuF..."），
  /// 海外区返回 JWT（三段点分隔）。处理逻辑：
  /// - JWT：解码第二段取 username（形如 "u_123456789"）
  /// - opaque token（中国区）：调用 Preference API 获取 uid，
  ///   拼成 `u_{uid}` 作为 MQTT username。
  ///   参考 pybambu bambu_cloud.py：GET /v1/design-user-service/my/preference
  ///   → 返回 JSON 的 uid 字段 → username = "u_{uid}"
  static Future<String> _resolveUsername({
    required String token,
    required BambuRegion region,
  }) async {
    final parts = token.split('.');
    // JWT 格式（三段）→ 本地解码
    if (parts.length >= 2) {
      try {
        var b64 = parts[1];
        b64 = b64.replaceAll('-', '+').replaceAll('_', '/');
        b64 += '=' * ((4 - b64.length % 4) % 4);
        final payload = utf8.decode(base64.decode(b64));
        final payloadJson = jsonDecode(payload) as Map<String, dynamic>;
        final username = payloadJson['username'] as String?;
        if (username != null && username.isNotEmpty) {
          return username;
        }
      } catch (_) {
        // JWT 解析失败，按 opaque token 处理
      }
    }

    // opaque token（中国区）：调用 Preference API 获取 uid
    try {
      final url = '${region.apiBaseUrl}/v1/design-user-service/my/preference';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          ..._bblHeaders,
          'Authorization': 'Bearer $token',
        },
      ).timeout(_timeout);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final uid = json['uid'];
        if (uid != null) {
          return 'u_$uid';
        }
      }
    } catch (_) {
      // Preference API 调用失败，fallback 到 token 本身
    }

    // 最终 fallback：用 token 本身（可能认证失败，但至少不会卡住）
    return token;
  }

  // ===== 上传预设到拓竹云端 =====
  //
  // 通过抓包 Bambu Studio 的 PATCH/POST /v1/iot-service/api/slicer/setting 接口实现。
  // 这是逆向协议，拓竹可能随时改接口或加签名校验，使用风险自负。
  //
  // 关键 Headers：
  // - Authorization: Bearer {accessToken}
  // - X-BBL-Client-ID: slicer:{userId}:{4位hex}（从 username u_xxx 提取 userId）
  // - X-BBL-Device-ID: {uuid v4}（每客户端生成一次保存）
  // - X-BBL-Executable-info: Bambu Studio 可执行文件的代码签名信息（服务端实测不校验）
  // - X-BBL-Client-Name: BambuStudio
  // - X-BBL-Client-Version: 02.07.01.57
  //
  // 请求体：
  // {base_id, name, setting: {参数键值对, 含 inherits/print_settings_id/updated_time}, version}

  /// Bambu Studio 的代码签名信息（抓包获取，服务端不校验，直接复用）。
  static const _bambuStudioExecutableInfo =
      '{"cert_end_date":"2029-03-12","cert_start_date":"2025-12-23","hash_value":"3dca1e74c49cdcd6b6f551500f6f7667af28d8db","issue_name":"GlobalSign GCC R45 EV CodeSigning CA 2020","serial_number":"23009bd87d891a5405b02fbc","sign_date":"2026-06-01T17:16:16Z","subject_name":"Shanghai Lunkuo Technology Co., Ltd","verify_result":"0"}';

  /// 模拟 Bambu Studio 的上传请求头。
  static Map<String, String> _bambuStudioHeaders(
    String accessToken,
    String username,
  ) {
    // 从 username "u_1234567890" 提取 userId "1234567890"
    final userId = username.startsWith('u_') ? username.substring(2) : username;
    // 生成 4 位随机 hex 作为 Client-ID 后缀
    final random = Random();
    final hexSuffix =
        List.generate(4, (_) => random.nextInt(16).toRadixString(16)).join();
    return {
      'User-Agent':
          'bambu_network_agent/${BambuClientVersion.networkAgentStudio}',
      'X-BBL-Client-ID': 'slicer:$userId:$hexSuffix',
      'X-BBL-Client-Name': 'BambuStudio',
      'X-BBL-Client-Type': 'slicer',
      'X-BBL-Client-Version': BambuClientVersion.bambuStudio,
      'X-BBL-Device-ID': _deviceId,
      'X-BBL-Language': 'zh-CN',
      'X-BBL-OS-Type': 'windows',
      'X-BBL-OS-Version': '10.0.26200',
      'X-BBL-Agent-Version': BambuClientVersion.networkAgentStudio,
      'X-BBL-Executable-info': _bambuStudioExecutableInfo,
      'X-BBL-Agent-OS-Type': 'windows',
      'accept': 'application/json',
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    };
  }

  /// 客户端设备 ID（UUID v4 格式，进程内缓存）。
  static String get _deviceId {
    _cachedDeviceId ??= _generateUuidV4();
    return _cachedDeviceId!;
  }

  static String? _cachedDeviceId;

  /// 生成 UUID v4（不依赖第三方库，用于 X-BBL-Device-ID）。
  static String _generateUuidV4() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // 设置 version 和 variant 位
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// 上传参数预设到拓竹云端。
  ///
  /// - [settingId] 非空时 PATCH 更新已有预设；为空时 POST 新建。
  /// - [baseId] 继承的系统预设 ID（如 "GP079"）。
  /// - [name] 预设名称。
  /// - [setting] 参数键值对（全部为字符串，包含 inherits/print_settings_id/updated_time）。
  /// - [version] Bambu Studio 配置版本（默认 "2.6.0.2"）。
  ///
  /// 成功时返回云端分配的 setting_id（新建时从响应中提取，更新时原样返回）。
  /// 失败时抛 [BambuCloudException]。
  static Future<String> uploadPresetToCloud({
    required BambuCloudSession session,
    String? settingId,
    required String baseId,
    required String name,
    required Map<String, String> setting,
    String version = '2.6.0.2',
  }) async {
    final url = settingId == null
        ? '${session.region.apiBaseUrl}/v1/iot-service/api/slicer/setting'
        : '${session.region.apiBaseUrl}/v1/iot-service/api/slicer/setting/$settingId';
    final method = settingId == null ? 'POST' : 'PATCH';

    final body = jsonEncode({
      'base_id': baseId,
      'name': name,
      'setting': setting,
      'version': version,
    });

    final headers = _bambuStudioHeaders(session.accessToken, session.username);

    http.Response response;
    if (method == 'POST') {
      response = await http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(_timeout);
    } else {
      response = await http
          .patch(Uri.parse(url), headers: headers, body: body)
          .timeout(_timeout);
    }

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final message = json['message'] as String? ?? '';
    if (message != 'success') {
      throw BambuCloudException(
        '云端返回异常：${json['error'] ?? message}',
        category: BambuCloudErrorCategory.protocol,
        statusCode: response.statusCode,
      );
    }

    // 新建时从响应里取 setting_id（若响应包含）；更新时原样返回
    if (settingId != null) return settingId;
    final newId = json['setting_id'] as String?;
    if (newId != null && newId.isNotEmpty) return newId;

    // 新建但响应没返回 setting_id：调用方可以稍后通过拉取列表来获取
    debugPrint('[BambuCloud] 上传预设成功，但响应未返回 setting_id: ${response.body}');
    return '';
  }

  /// 拉取当前账号在拓竹云端保存的用户工艺预设。
  ///
  /// 不同区域/版本返回体存在 `settings`、`data.list` 或以 setting_id 为键的
  /// Map 等差异，因此这里只做协议层归一化，具体参数模型由上层解析。
  static Future<List<Map<String, dynamic>>> getUserPresets({
    required BambuCloudSession session,
  }) async {
    final headers = _bambuStudioHeaders(session.accessToken, session.username);
    final response = await http
        .get(buildUserPresetsUri(session), headers: headers)
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final summaries = normalizePrivatePresetList(decoded);
    return _loadPrivatePresetDetails(
      session: session,
      headers: headers,
      summaries: summaries,
    );
  }

  @visibleForTesting
  static Uri buildUserPresetsUri(BambuCloudSession session) {
    return Uri.parse(
      '${session.region.apiBaseUrl}/v1/iot-service/api/slicer/setting',
    ).replace(queryParameters: const {'version': '2.6.0.2'});
  }

  /// Extracts only the account-owned `private` buckets. Bambu returns the
  /// complete official catalog in adjacent `public` buckets, which must not
  /// be presented as the current user's cloud presets.
  @visibleForTesting
  static List<Map<String, dynamic>> normalizePrivatePresetList(
    dynamic payload,
  ) {
    if (payload is! Map) return normalizePresetList(payload);
    final root = Map<String, dynamic>.from(payload);
    final result = <Map<String, dynamic>>[];
    final publicById = <String, Map<String, dynamic>>{};
    var hasStructuredBuckets = false;

    for (final groupName in const ['print', 'printer', 'filament']) {
      final rawGroup = root[groupName];
      if (rawGroup is! Map) continue;
      final group = Map<String, dynamic>.from(rawGroup);
      if (!group.containsKey('private')) continue;
      hasStructuredBuckets = true;
      for (final item in normalizePresetList(group['public'])) {
        final id = _presetItemId(item);
        if (id != null) publicById[id] = item;
      }
    }

    if (!hasStructuredBuckets) return normalizePresetList(payload);

    for (final groupName in const ['print', 'printer', 'filament']) {
      final rawGroup = root[groupName];
      if (rawGroup is! Map) continue;
      final group = Map<String, dynamic>.from(rawGroup);
      for (final item in normalizePresetList(group['private'])) {
        final enriched = Map<String, dynamic>.from(item);
        enriched['preset_type'] = groupName;
        final baseId = enriched['base_id']?.toString();
        final base = baseId == null ? null : publicById[baseId];
        final baseName = base?['name']?.toString();
        if (baseName != null && baseName.isNotEmpty) {
          enriched['base_name'] = baseName;
        }
        result.add(enriched);
      }
    }
    return result;
  }

  static String? _presetItemId(Map<String, dynamic> item) {
    for (final key in const [
      'setting_id',
      'settingId',
      'preset_id',
      'setting_uuid',
      'id',
      'uuid',
      'config_id',
    ]) {
      final value = item[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> _loadPrivatePresetDetails({
    required BambuCloudSession session,
    required Map<String, String> headers,
    required List<Map<String, dynamic>> summaries,
  }) async {
    const concurrency = 4;
    final result = <Map<String, dynamic>>[];
    for (var start = 0; start < summaries.length; start += concurrency) {
      final end = min(start + concurrency, summaries.length);
      final batch = summaries.sublist(start, end);
      result.addAll(
        await Future.wait(
          batch.map(
            (summary) => _loadPrivatePresetDetail(
              session: session,
              headers: headers,
              summary: summary,
            ),
          ),
        ),
      );
    }
    return result;
  }

  static Future<Map<String, dynamic>> _loadPrivatePresetDetail({
    required BambuCloudSession session,
    required Map<String, String> headers,
    required Map<String, dynamic> summary,
  }) async {
    final settingId = _presetItemId(summary);
    if (settingId == null) return summary;
    final uri = Uri.parse(
      '${session.region.apiBaseUrl}/v1/iot-service/api/slicer/setting/'
      '${Uri.encodeComponent(settingId)}',
    );
    try {
      final response = await http.get(uri, headers: headers).timeout(_timeout);
      if (response.statusCode != 200) return summary;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return summary;
      return <String, dynamic>{
        ...summary,
        ...Map<String, dynamic>.from(decoded),
        'setting_id': settingId,
        'preset_type': summary['preset_type'],
        if (summary['base_name'] != null) 'base_name': summary['base_name'],
      };
    } catch (error) {
      debugPrint(
        '[BambuCloud] Failed to load preset detail $settingId: $error',
      );
      return summary;
    }
  }

  @visibleForTesting
  static List<Map<String, dynamic>> normalizePresetList(dynamic payload) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};

    bool looksLikePreset(Map<String, dynamic> map) {
      const payloadKeys = {
        'setting',
        'values',
        'config',
        'content',
      };
      if (map.keys.any(payloadKeys.contains)) return true;
      const idKeys = {
        'setting_id',
        'settingId',
        'preset_id',
        'setting_uuid',
        'id',
        'uuid',
        'config_id',
      };
      final hasId = map.keys.any(idKeys.contains);
      return hasId &&
          (map.containsKey('name') ||
              map.containsKey('base_id') ||
              map.containsKey('type'));
    }

    String? itemId(Map<String, dynamic> item) {
      for (final key in const [
        'setting_id',
        'settingId',
        'preset_id',
        'setting_uuid',
        'id',
        'uuid',
        'config_id',
      ]) {
        final value = item[key]?.toString();
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    void visit(dynamic node, {String? fallbackKey}) {
      if (node is String) {
        final trimmed = node.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          try {
            visit(jsonDecode(trimmed), fallbackKey: fallbackKey);
          } catch (_) {
            // 普通字符串字段，不是嵌套 JSON。
          }
        }
        return;
      }
      if (node is List) {
        for (final value in node) {
          visit(value);
        }
        return;
      }
      if (node is! Map) return;

      final map = Map<String, dynamic>.from(node);
      if (looksLikePreset(map)) {
        final normalized = Map<String, dynamic>.from(map);
        final explicitId = itemId(normalized);
        if (explicitId != null &&
            fallbackKey != null &&
            fallbackKey.isNotEmpty) {
          normalized.putIfAbsent('name', () => fallbackKey);
        }
        final resolvedId = explicitId ?? fallbackKey;
        if (resolvedId != null && resolvedId.isNotEmpty) {
          normalized.putIfAbsent('setting_id', () => resolvedId);
        }
        final dedupeKey = resolvedId ?? jsonEncode(normalized);
        if (seen.add(dedupeKey)) result.add(normalized);
        return;
      }

      for (final entry in map.entries) {
        final childFallbackKey = entry.value is Map &&
                !const {
                  'data',
                  'result',
                  'settings',
                  'presets',
                  'user_presets',
                  'setting_list',
                  'list',
                }.contains(entry.key)
            ? entry.key
            : null;
        visit(entry.value, fallbackKey: childFallbackKey);
      }
    }

    visit(payload);
    return result;
  }

  /// 删除已上传到拓竹云端的用户预设。
  ///
  /// - 端点：`DELETE /v1/iot-service/api/slicer/setting/{settingId}`
  /// - 认证：Bearer token + BBL 系列请求头（同 [uploadPresetToCloud]）
  /// - 响应：`{"message":"success","code":null,"error":null}`
  ///
  /// 成功无返回值，失败抛 [BambuCloudException]。
  static Future<void> deletePresetFromCloud({
    required BambuCloudSession session,
    required String settingId,
  }) async {
    final url =
        '${session.region.apiBaseUrl}/v1/iot-service/api/slicer/setting/$settingId';
    final headers = _bambuStudioHeaders(session.accessToken, session.username);

    final response =
        await http.delete(Uri.parse(url), headers: headers).timeout(_timeout);

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final message = json['message'] as String? ?? '';
    if (message != 'success') {
      throw BambuCloudException(
        '云端返回异常：${json['error'] ?? message}',
        category: BambuCloudErrorCategory.protocol,
        statusCode: response.statusCode,
      );
    }
  }

  /// 解绑（unbind）指定设备。
  ///
  /// 逆向自 Bambu Studio 的"移除设备"功能：
  /// - 端点：`DELETE /v1/iot-service/api/user/bind`
  /// - 请求体：`{"dev_id": "<序列号>", "force": false}`
  /// - 认证：Bearer token + BBL 系列请求头
  /// - 响应：`{"message":"success","code":null,"error":null}`
  ///
  /// 抓包发现请求还带了 `x-bbl-app-certification-id` 和 `x-bbl-device-security-sign`
  /// 两个签名头，但服务端大概率不严格校验（与 X-BBL-Executable-info 一样），
  /// 因此这里先不传，如果调用失败再补。
  ///
  /// [force] 为 true 时强制解绑（即使设备在线/打印中），默认 false。
  /// 成功无返回值，失败抛 [BambuCloudException]。
  static Future<void> unbindDevice({
    required BambuCloudSession session,
    required String devId,
    bool force = false,
  }) async {
    final url = '${session.region.apiBaseUrl}/v1/iot-service/api/user/bind';
    final headers = _bambuStudioHeaders(session.accessToken, session.username);
    final body = jsonEncode({
      'dev_id': devId,
      'force': force,
    });

    final response = await http
        .delete(Uri.parse(url), headers: headers, body: body)
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw _formatHttpError(response.statusCode, response.body);
    }

    final json = _parseJsonResponse(response);
    final message = json['message'] as String? ?? '';
    if (message != 'success') {
      throw BambuCloudException(
        '云端返回异常：${json['error'] ?? message}',
        category: BambuCloudErrorCategory.protocol,
        statusCode: response.statusCode,
      );
    }
  }

  static BambuCloudException _formatHttpError(int statusCode, String body) {
    String? serverMsg;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      serverMsg = json['message'] as String?;
    } catch (_) {}

    BambuCloudErrorCategory category;
    String msg;

    switch (statusCode) {
      case 400:
        category = BambuCloudErrorCategory.client;
        msg = serverMsg ?? '请求参数错误（400）';
        break;
      case 401:
        category = BambuCloudErrorCategory.authentication;
        msg = serverMsg ?? '账号或密码错误（401）';
        break;
      case 403:
        category = BambuCloudErrorCategory.permission;
        msg = serverMsg ?? '无权限访问（403，可能被 Cloudflare 拦截，请稍后重试）';
        break;
      case 404:
        category = BambuCloudErrorCategory.protocol;
        msg = '接口不存在（404，拓竹可能已更新协议）';
        break;
      case 408:
        category = BambuCloudErrorCategory.network;
        msg = '请求超时（408）';
        break;
      case 429:
        category = BambuCloudErrorCategory.rateLimit;
        msg = '请求过于频繁（429），请稍后再试';
        break;
      case 500:
      case 502:
      case 503:
      case 504:
        category = BambuCloudErrorCategory.server;
        msg = '拓竹服务器暂时不可用（$statusCode）';
        break;
      default:
        if (statusCode >= 500) {
          category = BambuCloudErrorCategory.server;
          msg = '拓竹服务器错误（$statusCode）';
        } else if (statusCode >= 400) {
          category = BambuCloudErrorCategory.client;
          msg = serverMsg ?? '请求失败（HTTP $statusCode）';
        } else {
          category = BambuCloudErrorCategory.unknown;
          msg = serverMsg ?? '请求失败（HTTP $statusCode）';
        }
    }
    return BambuCloudException(
      msg,
      category: category,
      statusCode: statusCode,
    );
  }

  /// 安全解析 JSON 响应。
  ///
  /// 应对拓竹协议变更或网关异常返回非 JSON / 非 Object 的情况，
  /// 解析失败时抛出 [BambuCloudErrorCategory.protocol] 异常而非崩溃。
  static Map<String, dynamic> _parseJsonResponse(http.Response response) {
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw BambuCloudException(
          '云端响应格式异常（非 JSON 对象）：${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}',
          category: BambuCloudErrorCategory.protocol,
          statusCode: response.statusCode,
        );
      }
      return parsed;
    } on BambuCloudException {
      rethrow;
    } catch (e) {
      throw BambuCloudException(
        '云端响应 JSON 解析失败：$e',
        category: BambuCloudErrorCategory.protocol,
        statusCode: response.statusCode,
      );
    }
  }

  /// 执行 HTTP 请求并在网络/服务器错误时有限重试。
  ///
  /// - 仅对 [BambuCloudException.isRetryable] 的错误重试（网络/服务器/限流）；
  ///   4xx 客户端错误（认证/权限/协议）不重试。
  /// - 重试间隔指数退避：第一次重试等 2 秒，第二次等 4 秒。
  /// - 默认 [maxRetries] = 1（共发 2 次请求）。
  ///
  /// **不应用于有副作用的接口**（如 sendVerificationCode 会重复发短信，
  /// unbindDevice 会重复解绑，loginWithCode 可能因验证码已用而失败）。
  /// 仅用于幂等 GET 接口（getDeviceList/getTaskList）。
  static Future<http.Response> _requestWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 1,
  }) async {
    int attempt = 0;
    while (true) {
      try {
        return await request();
      } on TimeoutException {
        attempt++;
        if (attempt > maxRetries) {
          throw const BambuCloudException(
            '请求超时，请检查网络连接',
            category: BambuCloudErrorCategory.network,
          );
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      } on http.ClientException catch (e) {
        attempt++;
        if (attempt > maxRetries) {
          throw BambuCloudException(
            '网络错误：${e.message}',
            category: BambuCloudErrorCategory.network,
          );
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      } on BambuCloudException catch (e) {
        if (!e.isRetryable || attempt >= maxRetries) rethrow;
        attempt++;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }
}

/// 密码登录结果。两种可能：直接成功 或 需要验证码。
class LoginResult {
  final BambuCloudSession? session;
  final bool needsVerificationCode;

  const LoginResult.success(BambuCloudSession s)
      : session = s,
        needsVerificationCode = false;

  const LoginResult.needsCode()
      : session = null,
        needsVerificationCode = true;
}

/// 拓竹云 API 异常。
class BambuCloudException implements Exception {
  final String message;

  /// 错误分类，便于上层针对性处理（重试/重新登录/提示协议变更）。
  final BambuCloudErrorCategory category;

  /// HTTP 状态码（若错误由 HTTP 响应触发，否则为 null）。
  final int? statusCode;

  const BambuCloudException(
    this.message, {
    this.category = BambuCloudErrorCategory.unknown,
    this.statusCode,
  });

  /// 是否可重试（网络/服务器/限流错误）。
  ///
  /// 4xx 客户端错误（认证/权限/协议）不重试，重试也不会成功。
  bool get isRetryable =>
      category == BambuCloudErrorCategory.network ||
      category == BambuCloudErrorCategory.server ||
      category == BambuCloudErrorCategory.rateLimit;

  @override
  String toString() => 'BambuCloudException: $message';
}
