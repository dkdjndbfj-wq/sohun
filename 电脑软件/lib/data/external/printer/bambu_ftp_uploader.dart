import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import 'printer_certificate_trust_store.dart';
import '../../../core/utils/zip_safety.dart';

/// 拓竹打印机 FTP/FTPS 上传客户端。
///
/// **协议来源**：逆向 ha-bambulab / pybambu 项目。
///
/// **拓竹 FTP 认证**：
/// - 主机：打印机 IP（LAN 模式）或云端映射（Cloud 模式不支持 FTP）
/// - 端口：990（FTPS - 隐式 TLS）
/// - 用户名：`bblp`
/// - 密码：LAN Access Code（11 位字母数字）
///
/// **上传路径**：
/// - 文件名建议用时间戳避免冲突：`/myfile_{timestamp}.3mf`
/// - 拓竹打印机会把上传的文件存到内部 SD 卡根目录
///
/// **MQTT 指令配合**：
/// 上传完成后，需通过 MQTT 发 `project_file` 指令：
/// - 老款机型（X1/P1/A1）：`url = "file:///sdcard/{filename}"`
/// - 新款机型（H2D/P2S/A2L 等）：`url = "ftp:///{filename}"`
/// - `param` = 3MF 内 G-code 路径，如 `"Metadata/plate_1.gcode"`
///
/// **限制**：
/// - 仅支持 LAN 模式（Cloud 模式打印机 FTP 不暴露公网）
/// - 不支持断点续传（拓竹 FTP 实现简单，STOR 即可）
/// - 大文件（>500MB）可能需要 1-2 分钟
class BambuFtpUploader {
  static const int _ftpPort = 990;
  static const String _username = 'bblp';

  /// FTP 上传超时（含连接 + 数据传输）
  static const Duration timeout = Duration(minutes: 5);

  /// 上传 3MF 文件到打印机。
  ///
  /// [host] 打印机 IP
  /// [accessCode] LAN Access Code（11 位）
  /// [filePath] 本地 3MF 文件路径
  /// [modelName] 打印机型号（用于决定 URL 格式：X1/P1/A1 用 file:///，H2D 等用 ftp:///）
  /// [onProgress] 进度回调（0.0 - 1.0）
  ///
  /// 返回上传后的 FTP URL（用于 MQTT project_file 指令的 url 字段）。
  ///
  /// 失败抛 [BambuFtpException]。
  static Future<String> uploadFile({
    required String serial,
    required String host,
    required String accessCode,
    required String filePath,
    required String modelName,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw BambuFtpException('文件不存在：$filePath');
    }

    final fileSize = await file.length();
    if (fileSize == 0) {
      throw const BambuFtpException('文件为空');
    }

    // 生成远端文件名（时间戳避免冲突）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = filePath.toLowerCase().endsWith('.3mf') ? '3mf' : 'gcode';
    final remoteName = 'myfile_$timestamp.$ext';

    debugPrint(
      '[BambuFtp] 开始上传: $filePath (${_formatSize(fileSize)}) → $host:$remoteName',
    );

    Socket? controlSocket;
    Socket? dataSocket;

    try {
      final certificateVerifier =
          await PrinterCertificateTrustStore.loadVerifier(
        serial: serial,
        host: host,
        service: PrinterTlsService.ftps,
      );
      bool verifyCertificate(X509Certificate certificate) =>
          certificateVerifier.verifyCertificate(certificate);

      // 1. 建立 FTPS 控制连接（隐式 TLS）
      controlSocket = await SecureSocket.connect(
        host,
        _ftpPort,
        timeout: const Duration(seconds: 15),
        onBadCertificate: verifyCertificate,
      );

      // 2. 读取欢迎消息
      final welcome = await _readResponse(controlSocket);
      if (!_isPositiveCompletion(welcome)) {
        throw BambuFtpException('FTP 服务器拒绝连接：$welcome');
      }

      // 3. 登录
      await _sendCommand(controlSocket, 'USER $_username');
      final passResp = await _sendCommand(controlSocket, 'PASS $accessCode');
      if (!_isPositiveCompletion(passResp)) {
        throw BambuFtpException('FTP 登录失败（accessCode 错误？）：$passResp');
      }

      final pbszResp = await _sendCommand(controlSocket, 'PBSZ 0');
      final protResp = await _sendCommand(controlSocket, 'PROT P');
      if (!_isPositiveCompletion(pbszResp) ||
          !_isPositiveCompletion(protResp)) {
        throw const BambuFtpException('打印机不支持加密数据通道，已停止上传');
      }

      // 4. 切换到被动模式（PASV），拓竹 FTP 不支持 PORT 主动模式
      await _sendCommand(controlSocket, 'TYPE I'); // 二进制模式
      final pasvResp = await _sendCommand(controlSocket, 'PASV');
      final dataPort = _parsePasvResponse(pasvResp);
      if (dataPort == null) {
        throw BambuFtpException('PASV 解析失败：$pasvResp');
      }

      // 5. 建立数据连接
      dataSocket = await SecureSocket.connect(
        host,
        dataPort,
        timeout: const Duration(seconds: 15),
        onBadCertificate: verifyCertificate,
      );

      // 6. 发送 STOR 指令
      await _sendCommand(controlSocket, 'STOR $remoteName');

      // 7. 流式上传文件内容
      final raf = await file.open();
      int sentBytes = 0;
      try {
        const chunkSize = 64 * 1024; // 64KB chunks
        while (sentBytes < fileSize) {
          final remaining = fileSize - sentBytes;
          final readSize = remaining < chunkSize ? remaining : chunkSize;
          final data = await raf.read(readSize);
          if (data.isEmpty) break;
          dataSocket.add(data);
          await dataSocket.flush();
          sentBytes += data.length;
          if (onProgress != null && fileSize > 0) {
            onProgress(sentBytes / fileSize);
          }
        }
        await dataSocket.flush();
      } finally {
        await raf.close();
      }

      // 8. 关闭数据连接，读取传输完成响应
      await dataSocket.close();
      dataSocket = null;
      final storResp = await _readResponse(controlSocket);
      if (!_isPositiveCompletion(storResp)) {
        throw BambuFtpException('上传失败：$storResp');
      }

      // 9. 退出
      await _sendCommand(controlSocket, 'QUIT');

      // 10. 根据机型生成 URL（参考 ha-bambulab const.py LEGACY_SDCARD_PRINTERS）
      final url = _buildPrintUrl(modelName, remoteName);
      debugPrint('[BambuFtp] 上传完成: $url');
      return url;
    } on SocketException catch (e) {
      throw BambuFtpException('网络错误：${e.message}');
    } on TimeoutException {
      throw const BambuFtpException('上传超时（5 分钟）');
    } finally {
      await dataSocket?.close();
      await controlSocket?.close();
    }
  }

  /// 发送 FTP 指令并等待响应。
  static Future<String> _sendCommand(Socket socket, String cmd) async {
    socket.writeln(cmd);
    await socket.flush();
    return _readResponse(socket);
  }

  /// 读取 FTP 响应（可能多行，以 3 位数字 + 空格开头表示结束）。
  static Future<String> _readResponse(Socket socket) async {
    final completer = Completer<String>();
    late StreamSubscription sub;
    final buffer = <int>[];

    sub = socket.listen(
      (data) {
        buffer.addAll(data);
        if (buffer.length > 64 * 1024) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.completeError(
              Exception('FTP 响应超过 64KB，可能服务器异常'),
            );
          }
          return;
        }
        // 检查是否收到完整响应（以 \r\n 结尾，且首字符是数字）
        final str = utf8.decode(buffer, allowMalformed: true);
        final lines = str.split('\r\n');
        if (lines.length >= 2) {
          // 最后一行是空字符串（\r\n 分隔后）
          final lastLine = lines[lines.length - 2];
          if (lastLine.length >= 4 && lastLine[3] == ' ') {
            sub.cancel();
            if (!completer.isCompleted) completer.complete(str.trim());
          }
        }
      },
      onError: (e) {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.completeError(BambuFtpException('FTP 读取错误：$e'));
        }
      },
      onDone: () {
        sub.cancel();
        if (!completer.isCompleted) {
          completer.complete(utf8.decode(buffer, allowMalformed: true).trim());
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        throw const BambuFtpException('FTP 响应超时');
      },
    );
  }

  /// 解析 PASV 响应，返回数据端口。
  ///
  /// 响应格式：`227 Entering Passive Mode (192,168,1,100,4,1)`
  /// 最后两个数字是端口的高低位：port = 4 * 256 + 1 = 1025
  static int? _parsePasvResponse(String response) {
    final match =
        RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)').firstMatch(response);
    if (match == null) return null;
    final p1 = int.tryParse(match.group(5)!);
    final p2 = int.tryParse(match.group(6)!);
    if (p1 == null || p2 == null) return null;
    return p1 * 256 + p2;
  }

  /// FTP 状态码：2xx 表示成功完成（正完成回复）。
  static bool _isPositiveCompletion(String response) {
    if (response.isEmpty) return false;
    final code = int.tryParse(response.substring(0, 3));
    return code != null && code >= 200 && code < 300;
  }

  /// 根据机型生成 MQTT project_file 指令的 url 字段。
  ///
  /// **来源**：ha-bambulab const.py 的 LEGACY_SDCARD_PRINTERS 列表。
  ///
  /// - 老款（X1/X1C/X1E/P1P/P1S/A1/A1MINI）：`file:///sdcard/{name}`
  /// - 新款（H2D/P2S/A2L/H2C/H2S/X2D 等）：`ftp:///{name}`
  static String _buildPrintUrl(String modelName, String remoteName) {
    final legacyModels = [
      'X1',
      'X1C',
      'X1E',
      'X1 Carbon',
      'P1P',
      'P1S',
      'A1',
      'A1MINI',
      'A1 Mini',
    ];

    // 归一化机型名（去空格、大写）
    final normalized = modelName.replaceAll(' ', '').toUpperCase();

    final isLegacy = legacyModels
        .any((m) => normalized == m.replaceAll(' ', '').toUpperCase());

    if (isLegacy) {
      return 'file:///sdcard/$remoteName';
    }
    return 'ftp:///$remoteName';
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// FTP 上传异常。
class BambuFtpException implements Exception {
  final String message;
  const BambuFtpException(this.message);

  @override
  String toString() => 'BambuFtpException: $message';
}

/// 3MF 内 G-code 路径解析（用于 MQTT project_file 的 param 字段）。
///
/// 拓竹 3MF 包结构：
/// ```
/// my_model.3mf
/// ├── Metadata/
/// │   ├── slice_info.config
/// │   └── plate_1.gcode    ← 这个就是 param
/// ├── Model/
/// │   └── model.stl
/// └── project_settings.config
/// ```
///
/// 多 plate 场景：`plate_1.gcode` / `plate_2.gcode` ...
/// 单 plate：默认 `Metadata/plate_1.gcode`
class BambuGcodePathResolver {
  /// 从 3MF 文件解析内部 G-code 路径。
  ///
  /// 返回如 `"Metadata/plate_1.gcode"`，失败返回默认值。
  static Future<String> resolveFrom3mf(
    String threeMfPath, {
    int plateIndex = 1,
  }) async {
    InputFileStream? input;
    try {
      final file = File(threeMfPath);
      if (!await file.exists() || !await isSafe3mfFile(file)) {
        throw const FormatException('3MF 文件超过安全资源限制');
      }
      input = InputFileStream(threeMfPath);
      final archive = ZipDecoder().decodeBuffer(input);
      if (!isSafe3mfArchive(archive)) {
        throw const FormatException('3MF 压缩包超过安全资源限制');
      }
      final requested = 'Metadata/plate_$plateIndex.gcode';
      if (archive.findFile(requested) != null) return requested;
      final paths = archive.files
          .where(
            (f) =>
                f.isFile &&
                RegExp(r'^Metadata/plate_\d+\.gcode$', caseSensitive: false)
                    .hasMatch(f.name),
          )
          .map((f) => f.name)
          .toList()
        ..sort();
      if (paths.isEmpty) {
        throw const FormatException('3MF 内没有可打印的 plate G-code');
      }
      if (paths.length > 1) {
        throw FormatException('3MF 不包含所选第 $plateIndex 盘，不能改发其他盘');
      }
      return paths.first;
    } catch (e) {
      debugPrint('[BambuFtp] 3MF G-code 路径解析失败: $e');
      rethrow;
    } finally {
      input?.closeSync();
    }
  }
}
