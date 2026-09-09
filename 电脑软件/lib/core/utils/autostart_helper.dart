import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows 开机自启助手。
///
/// P0-7 修复：原设置页"开机自启"开关为空实现，现通过操作 Windows 注册表
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 实现真实的开机自启。
///
/// 仅 Windows 平台生效；其他平台 [setEnabled] 始终返回 false。
class AutostartHelper {
  AutostartHelper._();

  /// 注册表 Run 键路径（用户级，无需管理员权限）。
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// 注册表值名称（用应用名标识，避免与其他程序冲突）。
  static const _valueName = 'BambuConsumableStats';

  /// 设置开机自启状态。
  ///
  /// [enabled] 为 true 时写入注册表（值为当前 exe 路径），
  /// 为 false 时删除注册表项。
  /// 返回操作是否成功。
  static Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) {
      debugPrint('[Autostart] 非 Windows 平台，跳过开机自启设置');
      return false;
    }
    try {
      final exePath = Platform.resolvedExecutable;
      if (exePath.isEmpty) return false;

      if (enabled) {
        // reg add 写入自启项（用引号包裹 exe 路径，防止路径含空格出错）
        final result = await Process.run(
          'reg',
          [
            'add',
            _runKey,
            '/v',
            _valueName,
            '/t',
            'REG_SZ',
            '/d',
            '"$exePath"',
            '/f',
          ],
        );
        return result.exitCode == 0;
      } else {
        // reg delete 删除自启项（/f 静默删除，项不存在时不报错）
        final result = await Process.run(
          'reg',
          ['delete', _runKey, '/v', _valueName, '/f'],
        );
        // exitCode 1 也算成功（项本就不存在）
        return result.exitCode == 0 || result.exitCode == 1;
      }
    } catch (e) {
      debugPrint('[Autostart] 设置开机自启失败: $e');
      return false;
    }
  }

  /// 查询当前开机自启是否已启用。
  ///
  /// 通过 reg query 检查注册表项是否存在。
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run(
        'reg',
        ['query', _runKey, '/v', _valueName],
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
