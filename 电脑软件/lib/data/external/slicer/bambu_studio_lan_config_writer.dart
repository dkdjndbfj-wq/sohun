import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Bambu Studio LAN 直连配置写入器。
///
/// 通过修改 Bambu Studio 的配置文件（BambuStudio.conf），将打印机的
/// 序列号和 Access Code 写入 `user_access_code` 字段，使 Bambu Studio
/// 启动后能通过 mDNS 自动发现局域网内的打印机并用 Access Code 直连。
///
/// **工作原理**（逆向自 Bambu Studio 配置文件分析）：
/// - 配置文件路径：`%APPDATA%\BambuStudio\BambuStudio.conf`
/// - 文件格式：JSON + 末尾一行 `# MD5 checksum XXXXXXXX`
/// - `user_access_code` 字段是 `Map<String, String>`，key 是设备序列号，value 是 access code
/// - Bambu Studio 不强制校验 MD5（实验验证），运行时会自动更新 MD5
/// - Bambu Studio 启动后通过 mDNS 扫描局域网，发现设备后用 `user_access_code` 中的 access code 认证
///
/// **使用场景**：
/// - 用户在耗材统计软件中添加了 LAN 打印机后，一键写入 Bambu Studio 配置
/// - 用户不需要在 Bambu Studio 里手动输入 IP 和 Access Code
/// - 打开 Bambu Studio 即可直接使用打印机
///
/// **限制**：
/// - 仅 Windows（依赖 %APPDATA% 环境变量）
/// - Bambu Studio 必须处于关闭状态（运行时修改会被覆盖）
/// - 电脑和打印机必须在同一局域网（mDNS 发现的前提）
class BambuStudioLanConfigWriter {
  BambuStudioLanConfigWriter._();

  /// Bambu Studio 配置文件路径。
  static String get _confPath {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) {
      throw StateError('无法获取 APPDATA 环境变量');
    }
    return '$appdata\\BambuStudio\\BambuStudio.conf';
  }

  /// 检查 Bambu Studio 是否已安装（配置文件是否存在）。
  static bool isInstalled() {
    try {
      return File(_confPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 检查 Bambu Studio 是否正在运行。
  ///
  /// Windows 上通过 tasklist 检查进程 `bambu-studio.exe`。
  static Future<bool> isRunning() async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq bambu-studio.exe', '/NH'],
      );
      return (result.stdout as String)
          .toLowerCase()
          .contains('bambu-studio.exe');
    } catch (_) {
      return false;
    }
  }

  /// 请求关闭正在运行的 Bambu Studio 进程。
  ///
  /// 默认不使用 `/F`，给 Bambu Studio 保存工程和正常退出的机会。
  /// 只有用户明确确认后，调用方才可传入 [force] 执行强制关闭。
  /// 返回 true 表示成功关闭（或本来就没运行）。
  static Future<bool> killIfRunning({bool force = false}) async {
    if (!await isRunning()) return true;
    try {
      final result = await Process.run(
        'taskkill',
        ['/IM', 'bambu-studio.exe', if (force) '/F'],
      );
      // taskkill 成功返回 0
      if (result.exitCode == 0) {
        // P1-13 修复：轮询确认进程已完全退出，避免文件句柄未释放导致后续写入失败
        // 旧实现固定 delay 800ms，但 Windows 进程 kill 是异步的，文件句柄可能未释放
        for (var i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (!await isRunning()) return true;
        }
        // 2 秒后仍未退出，再额外等待
        await Future.delayed(const Duration(milliseconds: 500));
        return !await isRunning();
      }
      return false;
    } catch (e) {
      debugPrint('[BambuStudioLanConfig] killIfRunning 失败: $e');
      return false;
    }
  }

  /// 读取 BambuStudio.conf 中当前登录账号的 userId（`app.preset_folder` 字段）。
  ///
  /// Bambu Studio 用 userId 作为 `user/<userId>/` 目录名，隔离不同账号的 preset。
  /// 返回 null 表示配置文件不存在或字段缺失。
  static String? getCurrentUserId() {
    try {
      final file = File(_confPath);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      final json = _parseConfJson(raw);
      final app = json['app'];
      if (app is! Map) return null;
      final v = app['preset_folder'];
      if (v is! String || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 读取 BambuStudio.conf 中当前的区域（`app.region` 字段）。
  ///
  /// 返回 "China" / "Overseas"，null 表示配置文件不存在或字段缺失。
  /// 用于反向同步：检测 Bambu Studio 里切换的账号属于哪个区域。
  static String? getCurrentRegion() {
    try {
      final file = File(_confPath);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      final json = _parseConfJson(raw);
      final app = json['app'];
      if (app is! Map) return null;
      final v = app['region'];
      if (v is! String || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 读取 Bambu Studio 用于网络请求指纹的客户端 UUID。
  ///
  /// 远程摄像头 URL 会携带该值；缺失时调用方应生成本软件自己的持久 UUID。
  static String? getSlicerUuid() {
    try {
      final file = File(_confPath);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      final json = _parseConfJson(raw);
      final app = json['app'];
      if (app is! Map) return null;
      final value = app['slicer_uuid'];
      if (value is! String || value.trim().isEmpty) return null;
      return value.trim();
    } catch (_) {
      return null;
    }
  }

  /// 切换 Bambu Studio 的登录账号配置。
  ///
  /// 修改 BambuStudio.conf 中的三个字段：
  /// - `app.preset_folder`：新账号的 userId（决定用哪个 `user/<userId>/` preset 目录）
  /// - `app.region`：区域名称（"China" / "Overseas"）
  /// - `app.iot_environment`：IoT 环境编号（中国区="3"，海外区="1"）
  ///
  /// **流程**：
  /// 1. 如果 Bambu Studio 在运行，先 kill（否则运行时修改会被覆盖）
  /// 2. 修改 conf 文件
  /// 3. 返回 true 表示 conf 已更新
  ///
  /// **token 限制**：
  /// Bambu Studio 的登录 token 存在加密的 `BambuNetworkEngine.conf` 中，
  /// 本软件无法直接修改。conf 切换后重启 Bambu Studio：
  /// - 如果该电脑之前登录过新账号，token 已缓存 → 自动登录
  /// - 如果没登录过 → Bambu Studio 显示未登录，需用户手动登录一次
  ///
  /// 返回值：
  /// - `true`：conf 修改成功
  /// - `false`：Bambu Studio 无法关闭 / 配置文件不存在
  static Future<bool> switchAccount({
    required String userId,
    required String regionCode,
  }) async {
    final file = File(_confPath);
    if (!file.existsSync()) {
      debugPrint('[BambuStudioAccount] 配置文件不存在，跳过切换');
      return false;
    }

    // 1. 请求 Bambu Studio 正常退出。自动账号切换绝不强杀进程；
    // 若应用未退出，本次 Studio 同步中止，用户数据不会因此丢失。
    if (await isRunning()) {
      final killed = await killIfRunning();
      if (!killed) {
        debugPrint('[BambuStudioAccount] 无法关闭 Bambu Studio，切换中止');
        return false;
      }
    }

    // 2. 修改 conf
    try {
      final raw = await file.readAsString();
      final json = _parseConfJson(raw);
      final app = Map<String, dynamic>.from((json['app'] as Map?) ?? {});

      app['preset_folder'] = userId;
      app['region'] = regionCode;
      // iot_environment：中国区=3，海外区=1
      app['iot_environment'] = regionCode == 'China' ? '3' : '1';

      json['app'] = app;

      final newJsonString = const JsonEncoder.withIndent('    ').convert(json);
      final md5Line = _extractMd5Line(raw);
      final newContent =
          md5Line != null ? '$newJsonString\n$md5Line\n' : '$newJsonString\n';

      await file.writeAsString(newContent);
      debugPrint(
        '[BambuStudioAccount] 已切换 conf → userId=$userId, region=$regionCode',
      );
      return true;
    } catch (e) {
      debugPrint('[BambuStudioAccount] 切换失败: $e');
      return false;
    }
  }

  /// 读取当前 `user_access_code` 中的所有条目。
  ///
  /// 返回 `Map<序列号, accessCode>`。如果配置文件不存在或字段不存在，返回空 Map。
  static Map<String, String> readAllAccessCodes() {
    try {
      final file = File(_confPath);
      if (!file.existsSync()) return {};

      final raw = file.readAsStringSync();
      final json = _parseConfJson(raw);
      final codes = json['user_access_code'];
      if (codes is! Map) return {};

      return codes.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    } catch (e) {
      debugPrint('[BambuStudioLanConfig] 读取 access_code 失败: $e');
      return {};
    }
  }

  /// 写入（或更新）一台打印机的 LAN Access Code。
  ///
  /// [serial]：打印机序列号（如 `03900D642930459`）
  /// [accessCode]：LAN Access Code（如 `13105221`）
  ///
  /// 如果该序列号已存在，会更新 access code；否则新增一条。
  ///
  /// 返回值：
  /// - `true`：写入成功
  /// - `false`：Bambu Studio 正在运行（拒绝写入以避免被覆盖）
  ///
  /// 异常：
  /// - [StateError]：Bambu Studio 未安装或配置文件不存在
  static Future<bool> writeLanAccessCode({
    required String serial,
    required String accessCode,
  }) async {
    final file = File(_confPath);
    if (!file.existsSync()) {
      throw StateError(
        '未检测到 Bambu Studio 配置文件，请先安装并启动一次 Bambu Studio',
      );
    }

    // 检查 Bambu Studio 是否在运行
    if (await isRunning()) {
      return false;
    }

    // 读取配置文件
    final raw = await file.readAsString();
    final json = _parseConfJson(raw);

    // 更新 user_access_code 字段
    final codes = Map<String, dynamic>.from(
      (json['user_access_code'] as Map?) ?? {},
    );
    codes[serial] = accessCode;
    json['user_access_code'] = codes;

    // 序列化并写回（保留末尾 MD5 行，Bambu Studio 不校验且会自动更新）
    final newJsonString = const JsonEncoder.withIndent('    ').convert(json);
    final md5Line = _extractMd5Line(raw);
    final newContent =
        md5Line != null ? '$newJsonString\n$md5Line\n' : '$newJsonString\n';

    await file.writeAsString(newContent);

    // 安全：accessCode 是 LAN 鉴权凭据，不得输出到日志。仅记录序列号。
    debugPrint('[BambuStudioLanConfig] 已写入 $serial 的 LAN 配置');
    return true;
  }

  /// 批量写入多台打印机的 LAN Access Code。
  ///
  /// [entries]：`Map<序列号, accessCode>`
  ///
  /// 返回 `true` 表示成功，`false` 表示 Bambu Studio 正在运行。
  static Future<bool> writeLanAccessCodes({
    required Map<String, String> entries,
  }) async {
    final file = File(_confPath);
    if (!file.existsSync()) {
      throw StateError(
        '未检测到 Bambu Studio 配置文件，请先安装并启动一次 Bambu Studio',
      );
    }

    if (await isRunning()) {
      return false;
    }

    final raw = await file.readAsString();
    final json = _parseConfJson(raw);

    final codes = Map<String, dynamic>.from(
      (json['user_access_code'] as Map?) ?? {},
    );
    codes.addAll(entries);
    json['user_access_code'] = codes;

    final newJsonString = const JsonEncoder.withIndent('    ').convert(json);
    final md5Line = _extractMd5Line(raw);
    final newContent =
        md5Line != null ? '$newJsonString\n$md5Line\n' : '$newJsonString\n';

    await file.writeAsString(newContent);

    debugPrint('[BambuStudioLanConfig] 批量写入 ${entries.length} 台设备');
    return true;
  }

  /// 移除一台打印机的 LAN Access Code。
  static Future<bool> removeLanAccessCode(String serial) async {
    final file = File(_confPath);
    if (!file.existsSync()) return false;

    if (await isRunning()) {
      return false;
    }

    final raw = await file.readAsString();
    final json = _parseConfJson(raw);

    final codes = Map<String, dynamic>.from(
      (json['user_access_code'] as Map?) ?? {},
    );
    if (!codes.containsKey(serial)) return true; // 本来就没有

    codes.remove(serial);
    json['user_access_code'] = codes;

    final newJsonString = const JsonEncoder.withIndent('    ').convert(json);
    final md5Line = _extractMd5Line(raw);
    final newContent =
        md5Line != null ? '$newJsonString\n$md5Line\n' : '$newJsonString\n';

    await file.writeAsString(newContent);

    debugPrint('[BambuStudioLanConfig] 已移除 $serial');
    return true;
  }

  /// 解析 BambuStudio.conf 为 JSON Map。
  ///
  /// 文件格式：JSON 内容 + 末尾一行 `# MD5 checksum XXXXXXXX`
  static Map<String, dynamic> _parseConfJson(String raw) {
    // 去掉末尾的 MD5 校验行
    final md5Line = _extractMd5Line(raw);
    String jsonStr;
    if (md5Line != null) {
      jsonStr = raw.substring(0, raw.indexOf(md5Line)).trimRight();
    } else {
      jsonStr = raw.trimRight();
    }

    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// 从原始内容中提取 MD5 校验行（含 `# MD5 checksum XXXX`）。
  /// 如果不存在返回 null。
  static String? _extractMd5Line(String raw) {
    final idx = raw.indexOf('# MD5 checksum');
    if (idx < 0) return null;
    // 取从 # MD5 开始到行尾
    final lineEnd = raw.indexOf('\n', idx);
    return lineEnd < 0
        ? raw.substring(idx).trimRight()
        : raw.substring(idx, lineEnd).trimRight();
  }
}
