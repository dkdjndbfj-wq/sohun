// G-code 自动清件脚本启发式扫描器。
//
// 无人值守模式下用于安全门：检测 G-code 尾部是否含「自动清件」脚本
// （通过挤出机大幅 X/Y 移动把打印件推下热床，实现连续打印）。
//
// 与拓竹默认 end_gcode 区别：
//   默认：M140 S0 关热床 → G1 Z10 抬喷嘴 → G1 X0 Y200 呈递打印件 → M84
//   清件：M140 S0 → G1 Z0.2 贴近热床 → G1 X255 Y200 推到角 → 反复铲刮
//
// 启发式评分（满分 130）：
//   - 注释关键字（eject/push off/clean bed 等）：+40
//   - X/Y 单次移动 ≥200mm：+25
//   - X 方向往返刮擦（≥2 次方向反转，幅度 ≥150mm）：+25
//   - Z 抬起 <5mm 或无 Z 抬起：+15
//   - M140 S0 后仍有大幅 X/Y 移动：+15
//   - 多次（≥3）大幅 X/Y 移动：+10
//
// ≥50 分判定为含自动清件脚本（默认 end_gcode 最多拿 25 分，安全）。
//
// **3MF 支持**：3MF 是 ZIP 容器，内含 Metadata/plate_*.gcode。
// 本扫描器解压 3MF 后取内嵌 G-code 的尾部行进行评分，
// 与纯 G-code 文件共用同一套启发式算法。
//
// **跨切片软件兼容**：
// - BambuStudio：`;LAYER_CHANGE` + `;LAYER:N` 双标记
// - PrusaSlicer：`;LAYER_CHANGE` + `;LAYER:N`
// - Cura：`;LAYER:N`（部分版本无 `;LAYER_CHANGE`）
// - 第三方 end_gcode 关键字扩展：clear purge、wipe tower、
//   drop part、kick out、auto remove、part removal
//
// 手动覆盖优先于自动检测：用户可在队列项徽章上手动标记，
// 用于启发式误判时的安全网。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../../../core/utils/zip_safety.dart';

/// 自动清件检测结果。
class AutoClearResult {
  /// 是否含自动清件脚本
  final bool hasAutoClear;

  /// 启发式评分
  final int score;

  /// 命中的特征列表（用于调试和 UI 展示）
  final List<String> matchedFeatures;

  /// 错误信息（文件读失败等），非 null 表示检测失败
  final String? error;

  const AutoClearResult({
    required this.hasAutoClear,
    required this.score,
    required this.matchedFeatures,
    this.error,
  });

  /// 检测失败
  factory AutoClearResult.error(String message) {
    return AutoClearResult(
      hasAutoClear: false,
      score: 0,
      matchedFeatures: const [],
      error: message,
    );
  }

  /// 未检测到
  factory AutoClearResult.notDetected(int score, List<String> features) {
    return AutoClearResult(
      hasAutoClear: false,
      score: score,
      matchedFeatures: features,
    );
  }

  /// 检测到
  factory AutoClearResult.detected(int score, List<String> features) {
    return AutoClearResult(
      hasAutoClear: true,
      score: score,
      matchedFeatures: features,
    );
  }

  @override
  String toString() =>
      'AutoClearResult(hasAutoClear=$hasAutoClear, score=$score, '
      'features=$matchedFeatures, error=$error)';
}

/// G-code 自动清件脚本启发式扫描器。
///
/// 仅扫描 G-code 尾部（最后一个 `;LAYER_CHANGE` 之后的行，或最后 200 行），
/// 不解析整个文件，大文件也能在毫秒级完成。
class AutoClearDetector {
  AutoClearDetector._();

  /// 判定阈值：分数 ≥ 此值视为含自动清件脚本
  static const int threshold = 50;

  /// 尾部扫描最大行数
  static const int _maxTailLines = 200;

  /// 单次移动幅度阈值（mm）：≥ 此值视为「大幅移动」
  static const double _largeMoveThreshold = 200.0;

  /// 铲刮往返幅度阈值（mm）
  static const double _scrapeMoveThreshold = 150.0;

  /// Z 抬起判定阈值（mm）：< 此值视为「未有效抬起」
  static const double _zLiftThreshold = 5.0;

  /// 自动清件脚本常见注释关键字（不区分大小写）
  ///
  /// 涵盖主流切片软件（BambuStudio/PrusaSlicer/Cura/OrcaSlicer）的
  /// end_gcode 注释风格 + 中英文社区常见命名。
  static const List<Pattern> _commentKeywords = [
    // 英文常用动词
    'eject',
    'push off',
    'push out',
    'kick off',
    'kick out',
    'remove part',
    'remove print',
    'clear bed',
    'clean bed',
    'scraper',
    'scrape',
    'drop part',
    'auto remove',
    'part removal',
    'clear purge',
    'wipe tower',
    'purge wipe',
    // 中文社区常用词
    '推件',
    '铲件',
    '清件',
    '清床',
    '推出',
    '推下',
    '自动清',
    '自动推',
    '自动铲',
  ];

  /// 检测 G-code 文件尾部是否含自动清件脚本。
  ///
  /// [filePath] G-code 或 3MF 文件绝对路径。
  /// 3MF 会自动解压取内嵌 G-code（Metadata/plate_1.gcode）。
  /// 返回 [AutoClearResult]；文件不存在或读取失败返回 error 结果
  static Future<AutoClearResult> detect(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return AutoClearResult.error('文件不存在');
    }

    try {
      final lower = filePath.toLowerCase();
      if (lower.endsWith('.3mf')) {
        // 3MF：解压取内嵌 G-code 尾部
        final tailLines = await _read3mfGcodeTailLines(file);
        if (tailLines.isEmpty) {
          return AutoClearResult.error('3MF 内未找到 G-code');
        }
        return _analyze(tailLines);
      }

      // 普通 G-code 文件
      final tailLines = await _readTailLines(file);
      if (tailLines.isEmpty) {
        return AutoClearResult.error('文件为空');
      }
      return _analyze(tailLines);
    } catch (e) {
      return AutoClearResult.error('读取失败: $e');
    }
  }

  /// 从 3MF (ZIP) 中提取 G-code 尾部行。
  ///
  /// 3MF 内 G-code 路径优先级：
  ///   1. Metadata/plate_1.gcode（拓竹多盘切片的第 1 盘）
  ///   2. Metadata/plate.gcode（单盘）
  ///   3. 根目录的 .gcode 文件（兜底）
  ///
  /// 只取尾部 200 行（end_gcode 段），避免全量解压大文件。
  static Future<List<String>> _read3mfGcodeTailLines(File file) async {
    // 文件大小检查：超过 50MB 的 3MF 不做全量解压，避免 OOM
    final fileSize = await file.length();
    if (fileSize > max3mfInputBytes) {
      return []; // 让 detect() 返回 error，UI 提示手动标记
    }
    final bytes = await file.readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
      if (!isSafe3mfArchive(archive)) return [];
    } catch (_) {
      return []; // 不是有效 ZIP
    }

    // 找 G-code 文件
    ArchiveFile? gcodeFile = archive.findFile('Metadata/plate_1.gcode') ??
        archive.findFile('Metadata/plate.gcode');
    if (gcodeFile == null) {
      // 兜底：找根目录或任意 .gcode 文件
      for (final f in archive) {
        if (f.name.toLowerCase().endsWith('.gcode')) {
          gcodeFile = f;
          break;
        }
      }
    }
    if (gcodeFile == null) return [];

    // 解压为字符串
    final content =
        utf8.decode(gcodeFile.content as List<int>, allowMalformed: true);
    final allLines = content.split('\n');

    // 找最后一个 LAYER_CHANGE
    int lastLayerChangeIndex = -1;
    for (int i = 0; i < allLines.length; i++) {
      if (allLines[i].contains(';LAYER_CHANGE') ||
          allLines[i].contains(';LAYER:')) {
        lastLayerChangeIndex = i;
      }
    }

    if (lastLayerChangeIndex >= 0 &&
        allLines.length - lastLayerChangeIndex > 5) {
      return allLines.sublist(lastLayerChangeIndex);
    }

    final start =
        allLines.length > _maxTailLines ? allLines.length - _maxTailLines : 0;
    return allLines.sublist(start);
  }

  /// 读取文件尾部行。
  ///
  /// 策略：先尝试定位最后一个 `;LAYER_CHANGE`，取其后所有行；
  /// 找不到则取最后 [_maxTailLines] 行。这样能聚焦到 end_gcode 段。
  static Future<List<String>> _readTailLines(File file) async {
    final fileSize = await file.length();
    const chunkSize = 64 * 1024; // 64KB
    final readStart = fileSize > chunkSize ? fileSize - chunkSize : 0;
    final raf = await file.open();
    try {
      await raf.setPosition(readStart);
      final bytes =
          await raf.read(readStart == 0 ? fileSize.toInt() : chunkSize);
      final content = utf8.decode(bytes, allowMalformed: true);
      final lines = content.split('\n');
      // 如果不是从头读，第一行可能不完整，丢弃
      if (readStart > 0 && lines.isNotEmpty) {
        lines.removeAt(0);
      }
      // 找最后一个 LAYER_CHANGE
      int lastLayerChangeIndex = -1;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains(';LAYER_CHANGE') ||
            lines[i].contains(';LAYER:')) {
          lastLayerChangeIndex = i;
        }
      }
      if (lastLayerChangeIndex >= 0 &&
          lines.length - lastLayerChangeIndex > 5) {
        return lines.sublist(lastLayerChangeIndex);
      }
      // 取最后 _maxTailLines 行
      final start =
          lines.length > _maxTailLines ? lines.length - _maxTailLines : 0;
      return lines.sublist(start);
    } finally {
      await raf.close();
    }
  }

  /// 分析尾部行，计算评分。
  static AutoClearResult _analyze(List<String> lines) {
    int score = 0;
    final features = <String>[];

    final moves = <_GcodeMove>[];
    bool sawM140Off = false; // 热床关闭
    double? maxZLift; // 最大 Z 抬起值
    bool hasCommentKeyword = false;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // 1. 注释关键字检测
      final lower = line.toLowerCase();
      for (final kw in _commentKeywords) {
        if (lower.contains(kw)) {
          hasCommentKeyword = true;
          break;
        }
      }

      // 2. 热床关闭标记
      if (RegExp(r'^M140\s+S\s*0').hasMatch(line)) {
        sawM140Off = true;
        continue;
      }

      // 3. G0/G1 移动指令解析
      final moveMatch = RegExp(r'^G[01]\s+(.*)').firstMatch(line);
      if (moveMatch != null) {
        final move = _GcodeMove.parse(moveMatch.group(1)!);
        if (move != null) {
          moves.add(move);
          // 记录 Z 抬起（Z 正值且无 E 回抽，视为抬喷嘴）
          if (move.z != null && move.z! > 0 && move.e == null) {
            maxZLift ??= 0;
            if (move.z! > maxZLift) maxZLift = move.z!;
          }
        }
      }
    }

    // 计算每条 move 相对上一条的 X/Y 差值
    double? lastX, lastY;
    final xDiffs = <double>[]; // 大幅 X 差值列表（带方向）
    int largeXYMoveCount = 0;
    var xyMoveCommandCount = 0;

    for (final m in moves) {
      if (m.x != null || m.y != null) xyMoveCommandCount++;
      if (m.x != null && lastX != null) {
        final dx = m.x! - lastX;
        if (dx.abs() >= _largeMoveThreshold) largeXYMoveCount++;
        if (dx.abs() >= _scrapeMoveThreshold) xDiffs.add(dx);
      }
      if (m.y != null && lastY != null) {
        final dy = m.y! - lastY;
        if (dy.abs() >= _largeMoveThreshold) largeXYMoveCount++;
      }
      if (m.x != null) lastX = m.x;
      if (m.y != null) lastY = m.y;
    }

    // 评分项 1：注释关键字（+40）
    if (hasCommentKeyword) {
      score += 40;
      features.add('注释含自动清件关键字 (+40)');
    }

    // 评分项 2：单次大幅 X/Y 移动（+25）
    if (largeXYMoveCount > 0) {
      score += 25;
      features.add(
        '$largeXYMoveCount 次大幅 X/Y 移动 (≥${_largeMoveThreshold}mm) (+25)',
      );
    }

    // 评分项 3：X 方向往返刮擦（+25）
    // 统计 xDiffs 中方向反转次数
    int xScrapeCount = 0;
    double? lastDirection;
    for (final dx in xDiffs) {
      final direction = dx > 0 ? 1.0 : -1.0;
      if (lastDirection != null && direction != lastDirection) {
        xScrapeCount++;
      }
      lastDirection = direction;
    }
    if (xScrapeCount >= 2) {
      score += 25;
      features.add('X 方向往返铲刮 $xScrapeCount 次 (+25)');
    }

    // 评分项 4：Z 抬起不足（+15）
    if (maxZLift == null || maxZLift < _zLiftThreshold) {
      score += 15;
      features.add(
        'Z 抬起 ${maxZLift?.toStringAsFixed(1) ?? "无"}mm (<${_zLiftThreshold}mm) (+15)',
      );
    }

    // 评分项 5：关热床后仍有大幅移动（+15）
    if (sawM140Off && largeXYMoveCount > 0) {
      score += 15;
      features.add('关热床后仍有大幅 X/Y 移动 (+15)');
    }

    // 评分项 6：多次大幅移动（+10）
    if (largeXYMoveCount >= 3) {
      score += 10;
      features.add('大幅移动 ≥3 次 (+10)');
    }

    final hasEjectionMotion =
        largeXYMoveCount > 0 || xDiffs.isNotEmpty || xyMoveCommandCount >= 2;
    if (score >= threshold && hasEjectionMotion) {
      return AutoClearResult.detected(score, features);
    }
    if (score >= threshold && !hasEjectionMotion) {
      features.add('未发现足够的 X/Y 推件运动，拒绝无人值守');
    }
    return AutoClearResult.notDetected(score, features);
  }
}

/// G-code 移动指令解析后的数据（仅保留坐标，差值在外部计算）。
class _GcodeMove {
  final double? x;
  final double? y;
  final double? z;
  final double? e;

  const _GcodeMove({this.x, this.y, this.z, this.e});

  /// 解析 G0/G1 指令参数部分，如 `X255 Y200 F3000`。
  static _GcodeMove? parse(String params) {
    double? x, y, z, e;
    for (final part in params.split(RegExp(r'\s+'))) {
      if (part.isEmpty) continue;
      final letter = part[0].toUpperCase();
      final value = double.tryParse(part.substring(1));
      if (value == null) continue;
      switch (letter) {
        case 'X':
          x = value;
          break;
        case 'Y':
          y = value;
          break;
        case 'Z':
          z = value;
          break;
        case 'E':
          e = value;
          break;
      }
    }
    if (x == null && y == null && z == null && e == null) return null;
    return _GcodeMove(x: x, y: y, z: z, e: e);
  }
}
