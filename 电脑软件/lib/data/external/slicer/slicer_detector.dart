import 'dart:io';

/// 切片软件检测抽象接口。
///
/// 抽象出"识别切片软件安装位置、输出目录、启动软件"等能力，
/// 便于未来扩展创想三维 CrealityPrint、OrcaSlicer 等其他切片软件。
///
/// 实现类需要：
/// 1. 在系统常见位置自动搜索切片软件可执行文件
/// 2. 识别其默认 G-code/3MF 输出目录
/// 3. 提供启动切片软件的能力（带图标）
abstract class SlicerDetector {
  /// 切片软件标识（如 "bambu_studio"、"creality_print"）
  String get id;

  /// 切片软件显示名（如 "Bambu Studio"）
  String get displayName;

  /// 图标资源路径（用于 UI 启动按钮）
  String? get iconAsset;

  /// 自动检测切片软件可执行文件路径。
  /// 找不到返回 null。
  Future<String?> detectExecutable();

  /// 自动检测切片软件默认输出目录。
  /// 找不到返回 null。
  Future<String?> detectOutputDirectory();

  /// 启动切片软件。
  /// [executablePath] 为 null 时尝试自动检测。
  /// [arguments] 可传入一个或多个待打开的源工程路径。
  /// 返回是否启动成功。
  Future<bool> launch({
    String? executablePath,
    List<String> arguments = const [],
  });

  /// 综合检测：返回可执行文件路径 + 输出目录 + 是否就绪。
  /// UI 一次调用拿全部信息。
  Future<SlicerStatus> detect() async {
    final exe = await detectExecutable();
    final out = await detectOutputDirectory();
    return SlicerStatus(
      detector: this,
      executablePath: exe,
      outputDirectory: out,
      isInstalled: exe != null,
    );
  }
}

/// 切片软件检测结果快照。
class SlicerStatus {
  final SlicerDetector detector;
  final String? executablePath;
  final String? outputDirectory;
  final bool isInstalled;

  const SlicerStatus({
    required this.detector,
    required this.executablePath,
    required this.outputDirectory,
    required this.isInstalled,
  });

  /// 是否完全就绪（已安装且输出目录可识别）
  bool get isReady => isInstalled && outputDirectory != null;

  @override
  String toString() =>
      '$runtimeType(installed=$isInstalled, exe=$executablePath, out=$outputDirectory)';
}

/// 切片软件检测工具函数。
class SlicerDetectUtils {
  SlicerDetectUtils._();

  /// 在候选路径列表中查找第一个存在的可执行文件。
  /// 路径可包含环境变量（已展开）。
  static Future<String?> findFirstExisting(List<String> candidates) async {
    for (final path in candidates) {
      try {
        final file = File(path);
        if (await file.exists()) return path;
      } catch (_) {
        // 路径非法或无权限，跳过
      }
    }
    return null;
  }

  /// 在候选目录列表中查找第一个存在的目录。
  static Future<String?> findFirstExistingDir(List<String> candidates) async {
    for (final path in candidates) {
      try {
        final dir = Directory(path);
        if (await dir.exists()) return path;
      } catch (_) {}
    }
    return null;
  }
}
