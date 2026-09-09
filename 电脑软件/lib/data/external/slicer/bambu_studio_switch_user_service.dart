import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/windows_runtime_libraries.dart';
import '../../../core/utils/native_process_output.dart';
import '../../../core/utils/native_account_log.dart';
import '../printer/bambu_cloud_models.dart';

/// Bambu Studio 账号免密切换结果。
class BambuSwitchUserResult {
  final bool success;
  final String? error;
  final List<String> logs;

  const BambuSwitchUserResult({
    required this.success,
    this.error,
    this.logs = const [],
  });
}

/// Bambu Studio 账号免密切换服务。
///
/// 通过独立编译的 switch_user_tool.exe 调用 bambu_networking.dll 的
/// `change_user` API，将当前账号的 token 加密写入 Bambu Studio 真实配置目录的
/// `BambuNetworkEngine.conf`，实现免登录切换账号。
///
/// **原理**：
///   1. 从 [BambuCloudSession] 读取当前活跃账号的 accessToken / region
///   2. 释放 switch_user_tool.exe / bambu_networking.dll / 证书 到临时目录
///   3. 写入临时 token.json（含 region 字段，用于决定 country_code）
///   4. 执行 switch_user_tool.exe <token_file>
///   5. switch_user_tool 内部：
///      - set_config_dir 指向 `%APPDATA%\BambuStudio`（真实配置目录）
///      - change_user 让 dll 把 token 加密持久化到 BambuNetworkEngine.conf
///      - connect_server 验证 token 有效
///
/// **与 [BambuBindService] 的区别**：
///   - bind_tool 的 set_config_dir 指向临时目录（避免污染配置）
///   - switch_user_tool 的 set_config_dir 指向真实 BambuStudio 目录（让 token 持久化）
///   - switch_user_tool 不调用 ping_bind（不需要绑定打印机）
///
/// **前置条件**：
///   - 已登录拓竹云账号（有有效 session）
///   - Bambu Studio 已安装（配置目录存在）
class BambuStudioSwitchUserService {
  BambuStudioSwitchUserService._();

  // 打包在 assets/bin/ 中的文件
  static const _exeAssetPath = 'assets/bin/switch_user_tool.exe';
  static const _dllAssetPath = 'assets/bin/bambu_networking.dll';
  static const _cerAssetPath = 'assets/bin/slicer_base64.cer';

  /// 释放所有运行时文件到临时目录，返回 exe 路径。
  ///
  /// DLL（23MB）和证书只在不存在时释放以节省时间；
  /// exe 每次都重新释放（体积小，保证使用最新版本）。
  static Future<String> _extractRuntimeFiles() async {
    final dir = await getApplicationSupportDirectory();
    final runtimeDir =
        Directory('${dir.path}\\secure_runtime\\bbl_switch_user');
    if (!runtimeDir.existsSync()) {
      runtimeDir.createSync(recursive: true);
    }
    await _restrictDirectoryAcl(runtimeDir.path);
    await stageWindowsRuntimeLibraries(targetDirectory: runtimeDir);

    // 释放 switch_user_tool.exe（每次释放，体积小）
    final exePath = '${runtimeDir.path}\\switch_user_tool.exe';
    final exeData = await rootBundle.load(_exeAssetPath);
    final exeBytes = exeData.buffer.asUint8List();
    await File(exePath).writeAsBytes(exeBytes);
    // 完整性校验（fail-closed）：防止临时目录被篡改
    await _verifyIntegrity(exePath, exeBytes, '$_exeAssetPath.sha256');

    // 释放 bambu_networking.dll（23MB，只在不存在时释放）
    final dllPath = '${runtimeDir.path}\\bambu_networking.dll';
    if (!File(dllPath).existsSync()) {
      final dllData = await rootBundle.load(_dllAssetPath);
      final dllBytes = dllData.buffer.asUint8List();
      await File(dllPath).writeAsBytes(dllBytes);
      await _verifyIntegrity(dllPath, dllBytes, '$_dllAssetPath.sha256');
    } else {
      // DLL 已存在时也校验完整性，防止攻击者预先放置恶意 DLL
      final existingBytes = await File(dllPath).readAsBytes();
      await _verifyIntegrity(dllPath, existingBytes, '$_dllAssetPath.sha256');
    }

    // 释放证书（只在不存在时释放）
    final cerPath = '${runtimeDir.path}\\slicer_base64.cer';
    if (!File(cerPath).existsSync()) {
      final cerData = await rootBundle.load(_cerAssetPath);
      final cerBytes = cerData.buffer.asUint8List();
      await File(cerPath).writeAsBytes(cerBytes);
      await _verifyIntegrity(cerPath, cerBytes, '$_cerAssetPath.sha256');
    } else {
      final existingBytes = await File(cerPath).readAsBytes();
      await _verifyIntegrity(
        cerPath,
        existingBytes,
        '$_cerAssetPath.sha256',
      );
    }

    return exePath;
  }

  /// 写入临时 token.json（switch_user_tool 读取此文件获取 token + region）。
  ///
  /// **关键**：包含 `region` 字段（"China" / "Overseas"），
  /// switch_user_tool 据此决定 country_code（"CN" / "WW"）。
  static Future<String> _writeTokenJson(
    String runtimeDir,
    BambuCloudSession session,
  ) async {
    final tokenPath = '$runtimeDir\\switch_token.json';
    final tokenData = {
      'token': session.accessToken,
      'accessToken': session.accessToken,
      'refreshToken': session.refreshToken ?? session.accessToken,
      'expiresIn': session.expiresAt == null
          ? 31536000
          : session.expiresAt!
              .difference(DateTime.now())
              .inSeconds
              .clamp(0, 31536000),
      'refreshExpiresIn': session.refreshExpiresAt == null
          ? 31536000
          : session.refreshExpiresAt!
              .difference(DateTime.now())
              .inSeconds
              .clamp(0, 31536000),
      'username': session.username,
      'account': session.email,
      // region 字段：switch_user_tool 据此决定 country_code
      'region': session.region.code,
      'uid': int.tryParse(session.username.replaceAll('u_', '')) ?? 0,
      'login_response': {
        'accessToken': session.accessToken,
        'refreshToken': session.refreshToken ?? session.accessToken,
        'expiresIn': session.expiresAt == null
            ? 31536000
            : session.expiresAt!
                .difference(DateTime.now())
                .inSeconds
                .clamp(0, 31536000),
        'refreshExpiresIn': session.refreshExpiresAt == null
            ? 31536000
            : session.refreshExpiresAt!
                .difference(DateTime.now())
                .inSeconds
                .clamp(0, 31536000),
      },
    };
    await File(tokenPath).writeAsString(jsonEncode(tokenData));
    // 安全：设置 ACL，仅当前用户可读写，防止明文 token 被同机其他进程读取
    await _restrictFileAcl(tokenPath);
    return tokenPath;
  }

  /// 用 icacls 限制文件 ACL，仅当前用户可读写。
  static Future<void> _restrictFileAcl(String filePath) async {
    try {
      final user = Platform.environment['USERNAME'] ?? '';
      if (user.isEmpty) return;
      final result = await Process.run('icacls', [
        filePath,
        '/inheritance:r',
        '/grant:r',
        '$user:F',
      ]);
      if (result.exitCode != 0) {
        debugPrint('[SwitchUser] ACL 设置失败（非致命）: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('[SwitchUser] icacls 调用失败（非致命）: $e');
    }
  }

  static Future<void> _restrictDirectoryAcl(String directoryPath) async {
    final user = Platform.environment['USERNAME'] ?? '';
    if (user.isEmpty) {
      throw StateError('无法确定当前 Windows 用户，拒绝释放账号切换工具');
    }
    final result = await Process.run('icacls', [
      directoryPath,
      '/inheritance:r',
      '/grant:r',
      '$user:(OI)(CI)F',
    ]);
    if (result.exitCode != 0) {
      throw StateError('无法加固账号切换工具目录权限: ${result.stderr}');
    }
  }

  /// 校验释放文件完整性：与 assets 中同路径的 .sha256 清单对比。
  /// **fail-closed**：清单缺失或不匹配时抛 StateError，debug 模式允许跳过。
  static Future<void> _verifyIntegrity(
    String filePath,
    List<int> writtenBytes,
    String manifestAssetPath,
  ) async {
    String? manifestData;
    try {
      manifestData = await rootBundle.loadString(manifestAssetPath);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SwitchUser] 跳过完整性校验（debug 模式无清单）: $manifestAssetPath');
        return;
      }
      throw StateError('完整性校验失败: 清单文件 $manifestAssetPath 不存在，'
          '生产构建必须包含 .sha256 清单');
    }
    final expected = manifestData.trim().toLowerCase();
    if (expected.isEmpty) {
      throw StateError('完整性校验失败: 清单 $manifestAssetPath 为空');
    }
    final expectedHash = expected.split(RegExp(r'\s+')).first;
    final actual = crypto.sha256.convert(writtenBytes).toString().toLowerCase();
    if (actual != expectedHash) {
      throw StateError('完整性校验失败: $filePath 哈希不匹配（预期 $expectedHash，实际 $actual），'
          '可能临时目录被篡改');
    }
  }

  static Future<void> _verifyRuntimeFiles(String runtimeDir) async {
    for (final entry in <(String, String)>[
      ('switch_user_tool.exe', '$_exeAssetPath.sha256'),
      ('bambu_networking.dll', '$_dllAssetPath.sha256'),
      ('slicer_base64.cer', '$_cerAssetPath.sha256'),
    ]) {
      final path = '$runtimeDir\\${entry.$1}';
      await _verifyIntegrity(
        path,
        await File(path).readAsBytes(),
        entry.$2,
      );
    }
  }

  /// 执行 Bambu Studio 账号切换。
  ///
  /// [session] - 当前活跃账号的 session（提供 token + region）
  /// [onLog] - 日志回调（可选，用于 UI 显示进度）
  ///
  /// 返回 [BambuSwitchUserResult]，成功时 success=true 表示 token 已
  /// 持久化到 BambuNetworkEngine.conf。
  ///
  /// **注意**：调用前应确保 Bambu Studio 已关闭（token 写入时进程不能占用配置）。
  /// 本方法不负责关闭/重启 Bambu Studio，由调用方（_switchBambuStudioAccount）管理。
  static Future<BambuSwitchUserResult> switchUser({
    required BambuCloudSession session,
    void Function(String log)? onLog,
  }) async {
    if (session.accessToken.isEmpty) {
      return const BambuSwitchUserResult(
        success: false,
        error: '账号 token 为空，请重新登录',
      );
    }

    final logs = <String>[];
    // tokenPath 在 try 外声明，便于 finally 中清理含明文 accessToken 的临时文件。
    String? tokenPath;

    try {
      onLog?.call('正在释放切换工具...');
      final exePath = await _extractRuntimeFiles();
      final runtimeDir = exePath.substring(0, exePath.lastIndexOf('\\'));

      onLog?.call('正在准备 token...');
      tokenPath = await _writeTokenJson(runtimeDir, session);

      onLog?.call('正在切换 Bambu Studio 账号...');
      // Re-read all executable inputs immediately before launch to narrow the
      // release-to-execution replacement window.
      await _verifyRuntimeFiles(runtimeDir);
      // 超时保护：switch_user_tool 内部流程
      // change_user → connect_server → 等待 15 秒，正常 30 秒内完成。
      // 资源修复：用 Process.start 替代 Process.run，超时后主动 kill 进程。
      final proc = await Process.start(
        exePath,
        [tokenPath],
        workingDirectory: runtimeDir,
        includeParentEnvironment: true,
      );
      final result = await collectNativeProcessOutput(
        proc,
        timeout: const Duration(minutes: 1),
      );

      final stdout = sanitizeNativeAccountLog(result.stdout.toString());
      final stderr = sanitizeNativeAccountLog(result.stderr.toString());

      final lines = stdout.split('\n').where((l) => l.trim().isNotEmpty);
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          logs.add(trimmed);
          onLog?.call(trimmed);
        }
      }

      // 判定成功：输出包含 "账号切换成功" 或 is_user_login=true
      final success = result.exitCode == 0 &&
          (stdout.contains('账号切换成功') ||
              stdout.contains('is_user_login = true'));

      if (success) {
        onLog?.call('Bambu Studio 账号 token 写入成功！');
        return BambuSwitchUserResult(success: true, logs: logs);
      } else {
        String? error;
        if (stdout.contains('is_user_login=false')) {
          error = 'token 写入失败（is_user_login=false），可能 token 已过期';
        } else if (stdout.contains('LoadLibrary 失败')) {
          error = 'DLL 加载失败，请检查 bambu_networking.dll 是否完整';
        } else if (stdout.contains('change_user = -')) {
          error = 'change_user 调用失败，token 可能无效';
        } else if (stderr.isNotEmpty) {
          error = '切换失败: $stderr';
        } else {
          error = '切换失败（exitCode=${result.exitCode}）';
        }
        onLog?.call('切换失败: $error');
        return BambuSwitchUserResult(
          success: false,
          error: error,
          logs: logs,
        );
      }
    } catch (e) {
      final safeError = sanitizeNativeAccountLog(e.toString());
      onLog?.call('执行失败: $safeError');
      return BambuSwitchUserResult(
        success: false,
        error: '执行切换工具失败: $safeError',
        logs: logs,
      );
    } finally {
      // 安全清理：token.json 含明文 accessToken，无论成功失败都删除，
      // 防止残留临时目录被其他进程读取。
      if (tokenPath != null) {
        try {
          final f = File(tokenPath);
          if (await f.exists()) await f.delete();
        } catch (_) {
          // 清理失败不影响主流程
        }
      }
    }
  }
}
