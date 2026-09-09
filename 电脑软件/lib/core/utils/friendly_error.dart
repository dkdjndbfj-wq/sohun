import 'dart:async';
import 'dart:io';

/// P2 体验改进：友好错误信息映射。
///
/// 把原始异常（stack trace / return code / 技术细节）转换为用户可读的中文提示。
/// 调用方在 catch 块中用 `friendlyError(e)` 替代 `'$e'` 或 `e.toString()`。
///
/// 原则：事实大于人性化。不夸大、不掩饰，但去掉技术栈细节。
String friendlyError(Object e, {String? context}) {
  final raw = e.toString();
  final fallback = context == null ? '操作失败，请重试' : '$context失败，请重试';

  // 网络类
  if (e is SocketException) {
    return '网络连接失败，请检查网络后重试';
  }
  if (e is HandshakeException) {
    return '安全连接建立失败，请检查系统时间与证书';
  }
  if (e is TimeoutException) {
    return context == null ? '操作超时，请稍后重试' : '$context超时，请稍后重试';
  }

  // HTTP / 云端类（BambuCloudException 等通过 message 字段判断）
  if (raw.contains('401') || raw.contains('Unauthorized')) {
    return '登录已失效，请重新登录';
  }
  if (raw.contains('403') || raw.contains('Forbidden')) {
    return '没有权限执行此操作';
  }
  if (raw.contains('404') || raw.contains('Not Found')) {
    return '请求的资源不存在';
  }
  if (raw.contains('429') || raw.contains('Too Many Requests')) {
    return '操作过于频繁，请稍后再试';
  }
  if (raw.contains('5') && raw.contains(RegExp(r'5\d\d'))) {
    return '服务器暂时不可用，请稍后重试';
  }

  // 文件系统类
  if (raw.contains('No such file or directory') ||
      raw.contains('The system cannot find the file')) {
    return '文件或目录不存在，请检查路径';
  }
  if (raw.contains('Permission denied') || raw.contains('Access is denied')) {
    return '没有访问权限，请检查文件权限';
  }
  if (raw.contains('disk full') || raw.contains('No space left')) {
    return '磁盘空间不足';
  }

  // 数据库类
  if (raw.contains('UNIQUE constraint') ||
      raw.contains('constraint failed') ||
      raw.contains('SQLITE_CONSTRAINT')) {
    return '已有相同记录，请勿重复添加';
  }
  if (raw.contains('database is locked') || raw.contains('SQLITE_BUSY')) {
    return '数据正在被占用，请稍后重试';
  }
  if (raw.contains('SqliteException') || raw.contains('SQLITE_')) {
    return '数据库操作失败，请重试';
  }

  if (e is FormatException) {
    return '数据格式不正确，请检查输入内容';
  }

  // 进程类
  if (raw.contains('exitCode')) {
    return '外部程序执行失败，请检查配置后重试';
  }

  var cleaned = raw;
  for (final prefix in const [
    'BambuCloudException: ',
    'Bad state: ',
    'StateError: ',
    'ArgumentError: ',
    'Exception: ',
  ]) {
    if (cleaned.startsWith(prefix)) {
      cleaned = cleaned.substring(prefix.length).trim();
      break;
    }
  }

  // 仅保留业务层主动抛出的中文说明，未知技术异常统一收敛。
  if (cleaned.isNotEmpty &&
      cleaned.length <= 120 &&
      RegExp(r'[\u4e00-\u9fff]').hasMatch(cleaned)) {
    return cleaned;
  }
  return fallback;
}
