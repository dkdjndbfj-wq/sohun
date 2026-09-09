import 'dart:io';

import 'package:flutter/foundation.dart';

import 'slicer_detector.dart';

typedef RegistryQueryRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Bambu Studio 切片软件检测器。
///
/// 自动识别 Bambu Studio 在 Windows 上的安装位置和默认输出目录。
///
/// **安装位置候选**（按优先级）：
/// 1. `%PROGRAMFILES%\Bambu Studio\bambu-studio.exe`（系统级安装）
/// 2. `%LOCALAPPDATA%\Programs\Bambu Studio\bambu-studio.exe`（用户级安装）
/// 3. Windows 注册表 App Paths/卸载信息（自定义安装目录兜底）
///
/// **输出目录候选**：
/// 1. `%USERPROFILE%\BambuStudio\cache\`（默认缓存）
/// 2. `%USERPROFILE%\BambuStudio\`（项目根目录）
///
/// Bambu Studio 实际的 G-code 输出位置由用户在切片时选择，
/// 但默认会把项目文件（.3mf）和 G-code 缓存放在上述目录。
/// 用户可在设置中手动指定输出目录。
class BambuStudioDetector extends SlicerDetector {
  static const _registryAppPathKeys = <String>[
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\bambu-studio.exe',
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\bambu-studio.exe',
    r'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\bambu-studio.exe',
    r'HKCU\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\bambu-studio.exe',
  ];

  static const _registryUninstallRoots = <String>[
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  ];

  final RegistryQueryRunner _registryQuery;
  final bool _isWindows;
  final Map<String, String> _environment;

  BambuStudioDetector({
    RegistryQueryRunner? registryQuery,
    bool? isWindows,
    Map<String, String>? environment,
  })  : _registryQuery = registryQuery ??
            ((executable, arguments) => Process.run(executable, arguments)),
        _isWindows = isWindows ?? Platform.isWindows,
        _environment = environment ?? Platform.environment;

  @override
  String get id => 'bambu_studio';

  @override
  String get displayName => 'Bambu Studio';

  @override
  String? get iconAsset => 'assets/images/brands/拓竹.png';

  /// Windows 环境变量展开。`%PROGRAMFILES%` → `C:\Program Files`
  String _env(String name) => _environment[name] ?? '';

  @override
  Future<String?> detectExecutable() async {
    final candidates = <String>[];
    for (final root in <({String value, String suffix})>[
      (value: _env('PROGRAMFILES'), suffix: r'\Bambu Studio\bambu-studio.exe'),
      (value: _env('ProgramW6432'), suffix: r'\Bambu Studio\bambu-studio.exe'),
      (
        value: _env('LOCALAPPDATA'),
        suffix: r'\Programs\Bambu Studio\bambu-studio.exe',
      ),
    ]) {
      final rootValue = root.value;
      if (rootValue.isEmpty) continue;
      candidates.add('$rootValue${root.suffix}');
    }

    final detected = await SlicerDetectUtils.findFirstExisting(candidates);
    if (detected != null) return detected;
    return _detectExecutableFromRegistry();
  }

  /// 从 Windows App Paths 与卸载信息中查找安装路径。
  ///
  /// 这覆盖了便携安装器/自定义安装目录，且仅在常见路径未命中时运行，
  /// 不会影响 Linux/macOS 上的跨平台测试或启动。
  Future<String?> _detectExecutableFromRegistry() async {
    if (!_isWindows) return null;

    final candidates = <String>[];
    for (final key in _registryAppPathKeys) {
      final output = await _queryRegistry(['query', key]);
      candidates.addAll(registryPathsFromOutput(output));
    }
    for (final root in _registryUninstallRoots) {
      final output = await _queryRegistry(['query', root, '/s']);
      candidates.addAll(registryPathsFromOutput(output));
    }

    final existing = <String>[];
    for (final path in candidates) {
      if (path.isEmpty || existing.contains(path)) continue;
      existing.add(path);
    }
    return SlicerDetectUtils.findFirstExisting(existing);
  }

  Future<String> _queryRegistry(List<String> arguments) async {
    try {
      final result = await _registryQuery('reg.exe', arguments);
      if (result.exitCode != 0) return '';
      final value = result.stdout;
      return value is String ? value : value.toString();
    } catch (_) {
      return '';
    }
  }

  /// 提取 App Paths 默认值、卸载信息中的 DisplayIcon/InstallLocation。
  ///
  /// `reg query` 输出按 HKEY 子键分组；只接受包含 Bambu 的卸载项，
  /// 防止把其它产品的安装目录误识别为切片器。
  @visibleForTesting
  static List<String> registryPathsFromOutput(String output) {
    final blocks = <String, Map<String, String>>{};
    String? currentKey;
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('HKEY_')) {
        currentKey = trimmed;
        blocks.putIfAbsent(currentKey, () => <String, String>{});
        continue;
      }
      if (currentKey == null) continue;
      final match = RegExp(
        r'^(.+?)\s+REG_(?:SZ|EXPAND_SZ)\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      if (match == null) continue;
      blocks[currentKey]![match.group(1)!.trim().toLowerCase()] =
          match.group(2)!.trim();
    }

    final paths = <String>[];
    for (final entry in blocks.entries) {
      final key = entry.key.toLowerCase();
      final values = entry.value;
      final isAppPath = key.contains(r'\app paths\');
      final displayName = values['displayname']?.toLowerCase() ?? '';
      final isBambuUninstall = key.contains(r'\uninstall\') &&
          (key.contains('bambu') ||
              displayName.contains('bambu studio') ||
              displayName.contains('bambustudio'));
      if (!isAppPath && !isBambuUninstall) continue;

      if (isAppPath) {
        for (final value in values.values) {
          final path = _normalizeRegistryExecutable(value);
          if (path != null) paths.add(path);
        }
      }
      if (isBambuUninstall) {
        final icon = values['displayicon'];
        final location = values['installlocation'];
        final iconPath =
            icon == null ? null : _normalizeRegistryExecutable(icon);
        if (iconPath != null) paths.add(iconPath);
        if (location != null) {
          final normalized = _stripRegistryDecorations(location);
          if (normalized.isNotEmpty) {
            paths.add(
              '${normalized.replaceFirst(RegExp(r'[\\/]+$'), '')}\\bambu-studio.exe',
            );
          }
        }
      }
    }
    return paths;
  }

  static String? _normalizeRegistryExecutable(String raw) {
    var value = _stripRegistryDecorations(raw);
    final comma = value.toLowerCase().indexOf('.exe,');
    if (comma >= 0) value = value.substring(0, comma + 4);
    if (!value.toLowerCase().endsWith('.exe')) return null;
    return value;
  }

  static String _stripRegistryDecorations(String raw) {
    var value = raw.trim();
    if (value.length >= 2 && value.startsWith('"')) {
      final closing = value.indexOf('"', 1);
      if (closing > 1) value = value.substring(1, closing);
    }
    return value.trim();
  }

  @override
  Future<String?> detectOutputDirectory() async {
    final localAppData = _env('LOCALAPPDATA');
    final userProfile = _env('USERPROFILE');
    final candidates = <String>[
      // ✅ 真实路径（2026/07 实测）：发送打印任务时切片 G-code 缓存在此
      // 格式：%LOCALAPPDATA%\Temp\bamboo_model\<日期>\<时间>#<PID>#<plate>\Metadata\.<PID>.<plate>.gcode
      // DirectoryWatcher 监听 bamboo_model 根目录，递归监听子目录创建事件
      '$localAppData\\Temp\\bamboo_model',
      // 备选：BambuStudio 项目文件保存目录（用户手动保存的 .3mf）
      '$userProfile\\BambuStudio',
      // 旧版缓存
      '$userProfile\\BambuStudio\\cache',
      // 文档目录下的默认输出
      '$userProfile\\Documents\\BambuStudio',
    ];
    return SlicerDetectUtils.findFirstExistingDir(candidates);
  }

  @override
  Future<bool> launch({
    String? executablePath,
    List<String> arguments = const [],
  }) async {
    final exe = executablePath ?? await detectExecutable();
    if (exe == null) return false;
    try {
      // Windows 启动：用 Process.start detached，不阻塞当前进程
      await Process.start(
        exe,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 注册所有切片软件检测器的中心注册表。
/// UI 层通过这里获取所有支持的切片软件。
class SlicerRegistry {
  SlicerRegistry._();

  /// 所有已注册的切片软件检测器。
  /// 当前只有 BambuStudio，未来添加 CrealityPrint、OrcaSlicer 等。
  static final List<SlicerDetector> detectors = [
    BambuStudioDetector(),
    // TODO(v1.2): CrealityPrintDetector()
    // TODO(v1.2): OrcaSlicerDetector()
  ];

  /// 按 id 获取检测器
  static SlicerDetector? byId(String id) {
    for (final d in detectors) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 检测所有已安装的切片软件，返回已就绪的列表。
  static Future<List<SlicerStatus>> detectAll() async {
    final results = <SlicerStatus>[];
    for (final d in detectors) {
      final status = await d.detect();
      if (status.isInstalled) results.add(status);
    }
    return results;
  }
}
