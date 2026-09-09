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
import 'bambu_cloud_session_store.dart';

/// 拓竹打印机 PIN 码绑定结果
class BambuBindResult {
  final bool success;
  final String? returnValue;
  final String? error;
  final List<String>? logs;

  const BambuBindResult({
    required this.success,
    this.returnValue,
    this.error,
    this.logs,
  });

  @override
  String toString() => success
      ? 'BindResult(success, return=$returnValue)'
      : 'BindResult(failed: $error)';
}

/// 拓竹打印机 PIN 码绑定服务
///
/// 通过独立编译的 bind_tool.exe 调用 bambu_networking.dll 实现 bind,
/// 完全独立运行,不需要安装 Bambu Studio,不需要 Python/frida。
///
/// 所有依赖文件 (bind_tool.exe, bambu_networking.dll, slicer_base64.cer)
/// 都打包在 assets/bin/ 目录中,运行时释放到临时目录。
///
/// 原理 (Path E 验证):
///   1. 从加密 session store 读取当前登录账号的 accessToken
///   2. 释放 bind_tool.exe / bambu_networking.dll / 证书 到临时目录
///   3. 写入临时 token.json
///   4. 执行 bind_tool.exe --stdin <token.json>，通过 stdin 传入 PIN
///   5. bind_tool 内部: LoadLibrary → create_agent → init → change_user
///      → connect_server → ping_bind
///
/// 前置条件:
///   - 已登录拓竹云账号 (session store 有有效 token)
class BambuBindService {
  BambuBindService._();

  // 打包在 assets/bin/ 中的文件
  static const _exeAssetPath = 'assets/bin/bind_tool.exe';
  static const _dllAssetPath = 'assets/bin/bambu_networking.dll';
  static const _cerAssetPath = 'assets/bin/slicer_base64.cer';

  static List<String> _bindToolArguments(String tokenPath) =>
      <String>['--stdin', tokenPath];

  @visibleForTesting
  static List<String> bindToolArgumentsForTesting(String tokenPath) =>
      List<String>.unmodifiable(_bindToolArguments(tokenPath));

  /// 释放所有运行时文件到临时目录,返回 exe 路径
  /// 安全：释放后校验 exe/dll 的 SHA-256，防止临时目录被其他用户篡改替换导致 RCE。
  /// 预期哈希从 assets/bin/bind_tool.exe.sha256 读取（构建时生成）；
  /// 若清单文件不存在（开发期）则跳过校验并记录警告。
  static Future<String> _extractRuntimeFiles() async {
    final dir = await getApplicationSupportDirectory();
    final runtimeDir = Directory('${dir.path}\\secure_runtime\\bbl_bind');
    if (!runtimeDir.existsSync()) {
      runtimeDir.createSync(recursive: true);
    }
    await _restrictDirectoryAcl(runtimeDir.path);
    await stageWindowsRuntimeLibraries(targetDirectory: runtimeDir);

    // 释放 bind_tool.exe
    // P0-7 修复：exe 释放前先检查存在 + 校验完整性，
    // 避免每次重新释放（杀软锁定/进程未退出时 writeAsBytes 抛 FileSystemException）
    final exePath = '${runtimeDir.path}\\bind_tool.exe';
    var exeNeedRelease = true;
    if (File(exePath).existsSync()) {
      try {
        final existingBytes = await File(exePath).readAsBytes();
        await _verifyIntegrity(exePath, existingBytes, '$_exeAssetPath.sha256');
        exeNeedRelease = false; // 已存在且校验通过，跳过释放
      } catch (e) {
        // 校验失败：删除旧文件后重新释放
        try {
          await File(exePath).delete();
        } catch (_) {}
      }
    }
    if (exeNeedRelease) {
      final exeData = await rootBundle.load(_exeAssetPath);
      final exeBytes = exeData.buffer.asUint8List();
      await File(exePath).writeAsBytes(exeBytes);
      await _verifyIntegrity(exePath, exeBytes, '$_exeAssetPath.sha256');
    }

    // 释放 bambu_networking.dll (23MB, 只在不存在时释放以节省时间)
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

    // 释放证书
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

  /// 校验释放文件完整性：与 assets 中同路径的 .sha256 清单对比。
  ///
  /// **安全**：清单存在时强制校验，不匹配抛 StateError（fail-closed）。
  /// 清单缺失时同样抛 StateError，防止攻击者删除清单绕过校验。
  /// 仅在 debug 构建下允许跳过校验（开发期未生成清单）。
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
        debugPrint('[BindService] 跳过完整性校验（debug 模式无清单）: $manifestAssetPath');
        return;
      }
      throw StateError('完整性校验失败: 清单文件 $manifestAssetPath 不存在，'
          '生产构建必须包含 .sha256 清单');
    }
    final expected = manifestData.trim().toLowerCase();
    if (expected.isEmpty) {
      throw StateError('完整性校验失败: 清单 $manifestAssetPath 为空');
    }
    // 清单格式：<hash>  <filename>
    final expectedHash = expected.split(RegExp(r'\s+')).first;
    final actual = crypto.sha256.convert(writtenBytes).toString().toLowerCase();
    if (actual != expectedHash) {
      throw StateError('完整性校验失败: $filePath 哈希不匹配（预期 $expectedHash，实际 $actual），'
          '可能临时目录被篡改');
    }
  }

  /// 检查是否已登录拓竹云账号
  static Future<bool> isLoggedIn() async {
    try {
      final session = await BambuCloudSessionStore.loadSession();
      return session != null && session.accessToken.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 获取绑定前置条件状态
  static Future<BambuBindPrerequisites> checkPrerequisites() async {
    final loggedIn = await isLoggedIn();
    return BambuBindPrerequisites(loggedIn: loggedIn);
  }

  /// 写入临时 token.json (bind_tool 读取此文件获取 token)
  ///
  /// **安全**：写入后用 icacls 设置 ACL，限制只有当前用户可读，
  /// 防止同机其他用户进程读取明文 accessToken。
  static Future<String> _writeTokenJson(String runtimeDir) async {
    final session = await BambuCloudSessionStore.loadSession();
    if (session == null || session.accessToken.isEmpty) {
      throw StateError('未登录拓竹云账号');
    }

    final tokenPath = '$runtimeDir\\bind_token.json';
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
    // 设置 ACL：仅当前用户可读写，防止同机其他用户读取明文 token
    await _restrictFileAcl(tokenPath);
    return tokenPath;
  }

  /// 用 icacls 限制文件 ACL，仅当前用户可读写。
  ///
  /// 防止 `%TEMP%` 中的明文 token 文件被同机其他用户进程读取。
  /// 失败时不中断流程（ACL 是额外保护层，finally 块仍会删除文件）。
  static Future<void> _restrictFileAcl(String filePath) async {
    try {
      final user = Platform.environment['USERNAME'] ?? '';
      if (user.isEmpty) return;
      // 移除继承的 ACE，仅保留当前用户完全控制
      final result = await Process.run('icacls', [
        filePath,
        '/inheritance:r',
        '/grant:r',
        '$user:F',
      ]);
      if (result.exitCode != 0) {
        debugPrint('[BindService] ACL 设置失败（非致命）: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('[BindService] icacls 调用失败（非致命）: $e');
    }
  }

  static Future<void> _restrictDirectoryAcl(String directoryPath) async {
    final user = Platform.environment['USERNAME'] ?? '';
    if (user.isEmpty) throw StateError('无法确定当前 Windows 用户，拒绝释放运行工具');
    final result = await Process.run('icacls', [
      directoryPath,
      '/inheritance:r',
      '/grant:r',
      '$user:(OI)(CI)F',
    ]);
    if (result.exitCode != 0) {
      throw StateError('无法加固绑定工具目录权限: ${result.stderr}');
    }
  }

  static Future<void> _verifyRuntimeFiles(String runtimeDir) async {
    for (final entry in <(String, String)>[
      ('bind_tool.exe', '$_exeAssetPath.sha256'),
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

  /// 执行 PIN 码绑定
  ///
  /// [pin] - 6 位 PIN 码（打印机屏幕: 设置→网络→WLAN→PIN 码）
  /// [onLog] - 日志回调（可选，用于 UI 显示进度）
  ///
  /// 返回 [BambuBindResult]，成功时 success=true
  static Future<BambuBindResult> bindWithPin({
    required String pin,
    void Function(String log)? onLog,
  }) async {
    final pinCode = pin.trim().toUpperCase();
    if (pinCode.length != 6 || !RegExp(r'^[A-Z0-9]{6}$').hasMatch(pinCode)) {
      return const BambuBindResult(
        success: false,
        error: 'PIN 码必须是 6 位字母数字组合',
      );
    }

    // 检查前置条件
    final prereq = await checkPrerequisites();
    if (!prereq.loggedIn) {
      return const BambuBindResult(
        success: false,
        error: '请先登录拓竹云账号',
      );
    }

    final logs = <String>[];

    // 在 try 外声明，以便 finally 块可访问并清理
    String? tokenPath;
    try {
      onLog?.call('正在释放绑定工具...');
      final exePath = await _extractRuntimeFiles();
      final runtimeDir = exePath.substring(0, exePath.lastIndexOf('\\'));

      onLog?.call('正在准备 token...');
      tokenPath = await _writeTokenJson(runtimeDir);

      onLog?.call('正在执行绑定...');
      // 在启动前重新读取磁盘内容校验，缩短释放与执行之间的 TOCTOU 窗口。
      await _verifyRuntimeFiles(runtimeDir);
      // P0 修复: 加超时保护，防止 bind_tool.exe 卡死导致 UI 永久阻塞。
      // bind_tool 内部流程: LoadLibrary → create_agent → init → change_user
      // → connect_server → ping_bind，正常 30 秒内完成，给 2 分钟足够余量。
      // 资源修复：用 Process.start 替代 Process.run，超时后主动 kill 进程，
      // 避免超时后底层 exe 仍运行累积僵尸进程。
      final proc = await Process.start(
        exePath,
        _bindToolArguments(tokenPath),
        workingDirectory: runtimeDir,
        includeParentEnvironment: true,
      );
      // PIN 只通过匿名 stdin 管道发送，不进入进程命令行、任务管理器或日志。
      final result = await collectNativeProcessOutput(
        proc,
        timeout: const Duration(minutes: 2),
        inputLine: pinCode,
      );

      final stdout = sanitizeNativeAccountLog(result.stdout.toString());
      final stderr = sanitizeNativeAccountLog(result.stderr.toString());

      // 解析输出
      final lines =
          stdout.split('\n').where((l) => l.trim().isNotEmpty).toList();
      logs.addAll(lines.map((l) => l.trim()));

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          onLog?.call(trimmed);
        }
      }

      // 判断成功: 输出包含 "ping_bind = 0" 且包含 "成功"
      final success = result.exitCode == 0 &&
          stdout.contains('ping_bind = 0') && stdout.contains('成功');

      if (success) {
        // 提取返回值
        String? returnValue;
        final match = RegExp(r'ping_bind\s*=\s*(\d+)').firstMatch(stdout);
        if (match != null) {
          returnValue = match.group(1);
        }
        onLog?.call('绑定成功!');
        return BambuBindResult(
          success: true,
          returnValue: returnValue ?? '0',
          logs: logs,
        );
      } else {
        // 提取错误信息
        String? error;
        if (stdout.contains('ping_bind = -5')) {
          if (stdout.contains('404')) {
            error = 'PIN 码已失效或打印机已绑定';
          } else {
            error = '绑定失败 (ping_bind=-5, 可能 PIN 码错误或网络问题)';
          }
        } else if (stdout.contains('ping_bind = -')) {
          final match = RegExp(r'ping_bind\s*=\s*(-?\d+)').firstMatch(stdout);
          error = '绑定失败 (返回码=${match?.group(1)})';
        } else if (stdout.contains('connect_server') &&
            stdout.contains('connected=false')) {
          error = '无法连接拓竹云服务器, 请检查网络';
        } else if (stdout.contains('change_user') &&
            stdout.contains('is_user_login = false')) {
          error = '登录态失效, 请重新登录拓竹云账号';
        } else {
          error = '绑定失败${stderr.isNotEmpty ? ': $stderr' : ''}';
        }
        onLog?.call('绑定失败: $error');
        return BambuBindResult(
          success: false,
          error: error,
          logs: logs,
        );
      }
    } catch (e) {
      final safeError = sanitizeNativeAccountLog(e.toString());
      onLog?.call('执行失败: $safeError');
      return BambuBindResult(
        success: false,
        error: '执行绑定工具失败: $safeError',
        logs: logs,
      );
    } finally {
      // 清理 token.json：文件含 accessToken，不应残留在临时目录
      if (tokenPath != null) {
        try {
          await File(tokenPath).delete();
        } catch (_) {}
      }
    }
  }
}

/// 绑定前置条件
class BambuBindPrerequisites {
  /// 是否已登录拓竹云账号
  final bool loggedIn;

  const BambuBindPrerequisites({required this.loggedIn});

  /// 是否满足所有前置条件
  bool get isReady => loggedIn;

  /// 获取缺失条件的描述列表
  List<String> get missingItems {
    final items = <String>[];
    if (!loggedIn) {
      items.add('未登录拓竹云账号');
    }
    return items;
  }
}
