import 'dart:convert';
import 'dart:io';

import '../../models/filament_preset.dart';
import '../../models/plate_type.dart';
import '../../models/print_parameter.dart';
import '../../models/printer_preset.dart';
import '../../../features/parameters/process_preset_validator.dart';
import 'bambu_studio_lan_config_writer.dart';

/// Bambu Studio 打印参数导出器。
///
/// 支持两种导出格式：
/// - [exportToBambuStudioJson]：Bambu Studio 原生 Process Preset JSON，可直接导入 Bambu Studio
/// - [exportToBbsparam]：自定义 .bbsparam 格式（含元信息的 JSON），用于参数广场分享
///
/// 速度/加速度字段的数组转换：
/// - 标量字段直接用字符串值，如 `"layer_height": "0.2"`
/// - 速度/加速度字段转为数组格式，如 `"inner_wall_speed": ["150"]`
/// - 判断规则见 [PrintParameterPreset] 内的 `_isSpeedField`
class BambuStudioParamExporter {
  static const int maxImportBytes = 2 * 1024 * 1024;

  /// Bambu Studio 版本号（用于导出 JSON 的 version 字段）
  static const String bambuStudioVersion = '2.6.0.2';

  /// 导出为 Bambu Studio 原生 Process Preset JSON。
  ///
  /// 用户可以在 Bambu Studio 里直接导入此文件。
  /// 输出为扁平 JSON 结构，所有参数都是顶层 key。
  /// 速度/加速度字段自动转为数组格式 `["value"]`。
  static String exportToBambuStudioJson(PrintParameterPreset preset) {
    ProcessPresetValidator.validateOrThrow(preset);
    // 修正：如果 inherits 是默认值 fdm_process_common，导出为空字符串。
    // Bambu Studio 中具体工艺预设应继承 fdm_process_single_0.XX 中间层，
    // 但本软件未下载中间层 JSON，用户自定义预设若未明确指定继承，
    // 导出为空字符串让 Bambu Studio 视为独立预设，避免错误归类。
    final inheritsValue =
        preset.inherits == 'fdm_process_common' ? '' : preset.inherits;
    final json = <String, dynamic>{
      'type': 'process',
      'name': preset.name,
      'from': 'User',
      'inherits': inheritsValue,
      'instantiation': 'true',
      'print_settings_id': _sanitizeFileName(preset.name),
      'version': bambuStudioVersion,
      'compatible_printers': <String>[],
      // 所有参数字段（扁平结构，速度字段已转为数组）
      ...preset.quality.toJson(),
      ...preset.strength.toJson(),
      ...preset.speed.toJson(),
      ...preset.support.toJson(),
      ...preset.other.toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// 导出为自定义 .bbsparam 格式（含元信息的 JSON）。
  ///
  /// 用于参数广场分享，包含预设的元数据（作者、材料、场景等）和分组参数。
  static String exportToBbsparam(PrintParameterPreset preset) {
    ProcessPresetValidator.validateOrThrow(preset);
    return preset.toBbsparamJson();
  }

  /// 从 .bbsparam 格式导入。
  ///
  /// 解析 .bbsparam JSON 字符串，重建 [PrintParameterPreset] 对象。
  /// 导入后 updatedAt 设为当前时间。
  static PrintParameterPreset importFromBbsparam(String content) {
    final preset = PrintParameterPreset.fromBbsparamJson(content);
    ProcessPresetValidator.validateOrThrow(preset);
    return preset;
  }

  /// 在读取整个预设前执行大小检查，避免超大文件耗尽桌面端内存。
  static Future<PrintParameterPreset> importFromBbsparamFile(File file) async {
    if (await file.length() > maxImportBytes) {
      throw const FormatException('预设文件超过 2 MiB 上限');
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(maxImportBytes + 1);
      if (bytes.length > maxImportBytes) {
        throw const FormatException('预设文件超过 2 MiB 上限');
      }
      return importFromBbsparam(utf8.decode(bytes));
    } finally {
      await handle.close();
    }
  }

  /// 写入 Bambu Studio 用户配置目录。
  ///
  /// 路径：`%APPDATA%\BambuStudio\user\<userId>\process\<name>.json`
  ///
  /// 精确定位 userId：从 BambuStudio.conf 的 `app.preset_folder` 字段读取
  /// 当前登录账号的 userId，避免多账号场景下 preset 写到错误目录。
  /// 如果读不到 userId，回退到扫描第一个子目录（兼容旧版本）。
  ///
  /// 如果 process 目录不存在则创建。
  ///
  /// 返回写入的文件完整路径。写入失败抛异常。
  static Future<String> writeToBambuStudioUserDir(
    PrintParameterPreset preset,
  ) async {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) {
      throw StateError('无法获取 APPDATA 环境变量');
    }

    // H-4 修复：区分"未安装 Bambu Studio"和"目录结构异常"，给出友好提示
    final bblRoot = Directory('$appdata\\BambuStudio');
    if (!bblRoot.existsSync()) {
      throw StateError('未检测到 Bambu Studio 安装，请先安装 Bambu Studio 切片软件');
    }

    final userRoot = Directory('$appdata\\BambuStudio\\user');
    if (!userRoot.existsSync()) {
      throw StateError('Bambu Studio 用户目录不存在，请先启动一次 Bambu Studio 以初始化用户配置');
    }

    // 优先从 BambuStudio.conf 读取当前活跃账号的 userId（精确定位）
    final currentUserId = BambuStudioLanConfigWriter.getCurrentUserId();
    Directory? processDir;
    if (currentUserId != null) {
      final candidate =
          Directory('$appdata\\BambuStudio\\user\\$currentUserId\\process');
      if (!candidate.existsSync()) {
        candidate.createSync(recursive: true);
      }
      processDir = candidate;
    }

    // 回退：扫描 user 目录下所有子目录，找到或创建 process 目录
    if (processDir == null) {
      for (final userDir in userRoot.listSync()) {
        if (userDir is! Directory) continue;
        final candidate = Directory('${userDir.path}\\process');
        if (candidate.existsSync()) {
          processDir = candidate;
          break;
        }
      }
      // 如果没找到现成的 process 目录，在第一个 user 子目录下创建
      if (processDir == null) {
        for (final userDir in userRoot.listSync()) {
          if (userDir is! Directory) continue;
          processDir = Directory('${userDir.path}\\process');
          processDir.createSync(recursive: true);
          break;
        }
      }
    }

    if (processDir == null) {
      throw StateError('无法创建 process 目录（未找到有效的用户目录）');
    }

    // 文件名：预设名（去除非法字符）+ .json
    final safeName = _sanitizeFileName(preset.name);
    final filePath = '${processDir.path}\\$safeName.json';
    final file = File(filePath);
    final jsonContent = exportToBambuStudioJson(preset);
    await file.writeAsString(jsonContent);

    return filePath;
  }

  /// 把文件名中的非法字符替换为下划线。
  static String _sanitizeFileName(String name) {
    final illegal = RegExp(r'[<>:"/\\|?*]');
    return name.replaceAll(illegal, '_');
  }

  // ===== Filament Preset 导出 =====

  /// 导出 Filament Preset 为 Bambu Studio 原生 JSON。
  ///
  /// Bambu Studio 的 filament JSON 中所有字段都是数组（每通道一个值）。
  static String exportFilamentToJson(FilamentPreset preset) {
    final json = <String, dynamic>{
      'type': 'filament',
      'name': preset.name,
      'from': 'User',
      'inherits': preset.inherits,
      'instantiation': 'true',
      'filament_settings_id': _sanitizeFileName(preset.name),
      'version': bambuStudioVersion,
      // 所有参数字段（扁平结构，字段已转为数组）
      ...preset.temp.toJson(),
      ...preset.flow.toJson(),
      ...preset.fan.toJson(),
      ...preset.retraction.toJson(),
      ...preset.drying.toJson(),
      ...preset.properties.toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// 导出 Filament Preset 为 .bbsparam 格式（含元信息）。
  static String exportFilamentToBbsparam(FilamentPreset preset) {
    return preset.toBbsparamJson();
  }

  // ===== Printer Preset 导出 =====

  /// 导出 Printer Preset 为 Bambu Studio 原生 Machine JSON。
  ///
  /// 速度/加速度/Jerk 字段转为数组格式，其余为标量。
  static String exportPrinterToJson(PrinterPreset preset) {
    final json = <String, dynamic>{
      'type': 'machine',
      'name': preset.name,
      'from': 'User',
      'instantiation': 'true',
      'inherits': 'fdm_machine_common',
      'printer_settings_id': _sanitizeFileName(preset.name),
      'printer_model': preset.printerModel,
      'printer_structure': preset.printerStructure,
      'version': bambuStudioVersion,
      // 所有参数字段（扁平结构，速度字段已转为数组）
      ...preset.nozzle.toJson(),
      ...preset.bed.toJson(),
      ...preset.mechanical.toJson(),
      ...preset.features.toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// 导出 Printer Preset 为 .bbsparam 格式（含元信息）。
  static String exportPrinterToBbsparam(PrinterPreset preset) {
    return preset.toBbsparamJson();
  }

  // ===== 完整配置包导出 =====

  /// 导出完整的 Bambu Studio 配置包（Process + Filament + Printer）。
  ///
  /// 输出为单个合并 JSON，包含 3 个子对象：
  /// - `process`：工艺参数
  /// - `filament`：耗材丝配置
  /// - `printer`：打印机配置
  /// - `plate`：当前选中的打印板类型
  ///
  /// 可用于完整配置备份或在不同设备间迁移。
  static String exportToBambuStudioBundle({
    required PrintParameterPreset process,
    required FilamentPreset filament,
    required PrinterPreset printer,
    required PlateType plate,
  }) {
    final bundle = <String, dynamic>{
      'format': 'bambu_studio_bundle',
      'version': '1.0',
      'exported_at': DateTime.now().toIso8601String(),
      'plate': plate.name,
      'plate_label': plate.label,
      'process': jsonDecode(exportToBambuStudioJson(process)),
      'filament': jsonDecode(exportFilamentToJson(filament)),
      'printer': jsonDecode(exportPrinterToJson(printer)),
    };
    return const JsonEncoder.withIndent('  ').convert(bundle);
  }

  /// 写入 Filament Preset 到 Bambu Studio 用户配置目录。
  ///
  /// 路径：`%APPDATA%\BambuStudio\user\<userId>\filament\<name>.json`
  static Future<String> writeFilamentToBambuStudioUserDir(
    FilamentPreset preset,
  ) async {
    final dir = await _ensureUserSubDir('filament');
    final safeName = _sanitizeFileName(preset.name);
    final filePath = '${dir.path}\\$safeName.json';
    await File(filePath).writeAsString(exportFilamentToJson(preset));
    return filePath;
  }

  /// 写入 Printer Preset 到 Bambu Studio 用户配置目录。
  ///
  /// 路径：`%APPDATA%\BambuStudio\user\<userId>\machine\<name>.json`
  static Future<String> writePrinterToBambuStudioUserDir(
    PrinterPreset preset,
  ) async {
    final dir = await _ensureUserSubDir('machine');
    final safeName = _sanitizeFileName(preset.name);
    final filePath = '${dir.path}\\$safeName.json';
    await File(filePath).writeAsString(exportPrinterToJson(preset));
    return filePath;
  }

  /// 确保 Bambu Studio 用户目录下指定子目录存在。
  ///
  /// 扫描 user 目录下所有子目录，找到或创建指定名称的子目录。
  static Future<Directory> _ensureUserSubDir(String subDirName) async {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) {
      throw StateError('无法获取 APPDATA 环境变量');
    }
    // H-3 修复：与 writeToBambuStudioUserDir 一致，先检查 Bambu Studio 安装
    final bblRoot = Directory('$appdata\\BambuStudio');
    if (!bblRoot.existsSync()) {
      throw StateError('未检测到 Bambu Studio 安装，请先安装 Bambu Studio 切片软件');
    }
    final userRoot = Directory('$appdata\\BambuStudio\\user');
    if (!userRoot.existsSync()) {
      throw StateError('Bambu Studio 用户目录不存在，请先启动一次 Bambu Studio 以初始化用户配置');
    }

    // 扫描 user 目录下所有子目录，找到或创建目标子目录
    for (final userDir in userRoot.listSync()) {
      if (userDir is! Directory) continue;
      final candidate = Directory('${userDir.path}\\$subDirName');
      if (candidate.existsSync()) {
        return candidate;
      }
    }

    // 如果没找到现成目录，在第一个 user 子目录下创建
    for (final userDir in userRoot.listSync()) {
      if (userDir is! Directory) continue;
      final subDir = Directory('${userDir.path}\\$subDirName');
      subDir.createSync(recursive: true);
      return subDir;
    }

    throw StateError('无法创建 $subDirName 目录（未找到有效的用户目录）');
  }
}
