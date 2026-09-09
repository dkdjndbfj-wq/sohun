import 'dart:isolate';

import '../../../core/services/error_logger.dart';
import 'gcode_parser.dart';
import 'production_package_inspector.dart';
import 'slice_result.dart';
import 'threemf_parser.dart';

/// P1-3: 切片文件 Isolate 解析运行器。
///
/// **为什么需要 Isolate**：
/// - `GcodeParser._parseLayerMapping` 精细模式需要逐字节扫描整个 G-code 文件，
///   大文件（>100MB）解析耗时数秒，期间正则匹配和算术运算会阻塞 UI 主线程。
/// - `ThreemfParser` 解压 ZIP + 解析 XML 也是 CPU 密集任务。
/// - 虽然现有代码用 `await` 让出事件循环，但单次 `RegExp.firstMatch` 和
///   `ZipDecoder().decodeBytes` 内部的同步循环仍会造成 jank。
///
/// **方案**：用 `Isolate.run()`（Dart 3.0+）在独立 isolate 执行解析，
/// 主线程立即返回 Future，UI 保持流畅。
///
/// **数据传递**：`SliceResult` 和 `FilamentUsage` 仅含基本类型字段
/// （String/int/double/Map/List/DateTime），可通过 isolate 边界传递，
/// 无需手动序列化。
///
/// **使用方式**：调用方将 `GcodeParser.parseFile(path)` 替换为
/// `SliceIsolateRunner.parseGcode(path)` 即可。
class SliceIsolateRunner {
  SliceIsolateRunner._();

  /// 在 Isolate 中解析 G-code 文件。
  ///
  /// 参数语义与 [GcodeParser.parseFile] 完全一致。
  /// 返回 null 表示文件不存在或解析失败。
  ///
  /// **注意**：isolate 启动有 ~5ms 开销，小文件解析可能比同步更快。
  /// 但精细模式（enableLayerMapping=true）大文件解析时收益显著。
  static Future<SliceResult?> parseGcode(
    String filePath, {
    bool enableLayerMapping = false,
    String materialType = 'PLA',
  }) async {
    try {
      return await Isolate.run(
        () => GcodeParser.parseFile(
          filePath,
          enableLayerMapping: enableLayerMapping,
          materialType: materialType,
        ),
      );
    } catch (e, st) {
      // Isolate 启动失败或内部异常（parseFile 内部已 try-catch，
      // 这里捕获的是 isolate 基础设施错误，如 OOM）
      ErrorLogger.log(
        e,
        st,
        source: 'gcode_parser',
        level: ErrorLevel.error,
        context: {
          'phase': 'isolate_run_gcode',
          'filePath': filePath,
          'enableLayerMapping': enableLayerMapping,
        },
      );
      // 不在主 isolate 重跑同一坏文件，避免对大文件重复分配并冻结 UI。
      return null;
    }
  }

  /// 在 Isolate 中解析 3MF 文件。
  ///
  /// 参数语义与 [ThreemfParser.parseFile] 完全一致。
  /// 返回 null 表示文件不存在或不是有效 3MF。
  static Future<SliceResult?> parse3mf(
    String filePath, {
    bool enableLayerMapping = false,
    int plateIndex = 1,
  }) async {
    try {
      return await Isolate.run(
        () => ThreemfParser.parseFile(
          filePath,
          enableLayerMapping: enableLayerMapping,
          plateIndex: plateIndex,
        ),
      );
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'gcode_parser',
        level: ErrorLevel.error,
        context: {
          'phase': 'isolate_run_3mf',
          'filePath': filePath,
          'enableLayerMapping': enableLayerMapping,
        },
      );
      // 不在主 isolate 重跑同一坏文件，避免 3MF 解压再次造成 OOM。
      return null;
    }
  }

  /// 智能分发：根据文件扩展名自动选择 G-code 或 3MF 解析器。
  ///
  /// 统一入口，调用方无需关心文件类型。
  /// - `.3mf` → [parse3mf]
  /// - 其他（.gcode/.g/.gc/.ngc）→ [parseGcode]
  static Future<SliceResult?> parseAuto(
    String filePath, {
    bool enableLayerMapping = false,
    String materialType = 'PLA',
    int plateIndex = 1,
  }) async {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.3mf')) {
      return parse3mf(
        filePath,
        enableLayerMapping: enableLayerMapping,
        plateIndex: plateIndex,
      );
    }
    return parseGcode(
      filePath,
      enableLayerMapping: enableLayerMapping,
      materialType: materialType,
    );
  }

  /// Inspects plate/object relationships away from the Flutter UI isolate.
  static Future<ProductionPackageInspection?> inspectProductionPackage(
    String filePath,
  ) async {
    try {
      return await Isolate.run(
        () => ProductionPackageInspector.inspect(filePath),
      );
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'production_package_inspector',
        level: ErrorLevel.warning,
        context: {'filePath': filePath},
      );
      return null;
    }
  }
}
