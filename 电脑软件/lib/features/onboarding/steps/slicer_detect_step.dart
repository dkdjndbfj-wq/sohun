import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/external/slicer/bambu_studio_detector.dart';
import '../../../providers/onboarding_provider.dart';

/// 步骤5：检测切片软件（Bambu Studio）。
///
/// 自动检测可执行文件路径与输出目录；检测不到时引导用户手动选择。
/// 路径写入 OnboardingState，完成向导时由 complete() 落库到 SlicerPrefs。
/// 可跳过（留空也可下一步）。
class SlicerDetectStep extends ConsumerStatefulWidget {
  const SlicerDetectStep({super.key});

  @override
  ConsumerState<SlicerDetectStep> createState() => _SlicerDetectStepState();
}

class _SlicerDetectStepState extends ConsumerState<SlicerDetectStep> {
  final _detector = BambuStudioDetector();
  String? _exePath;
  String? _outputDir;
  bool _isDetecting = true;
  String? _detectError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAndDetect());
  }

  Future<void> _initAndDetect() async {
    // 预填：若向导 state 已有值则优先用
    final state = ref.read(onboardingProvider);
    final preExe = state.slicerExePath;
    final preOut = state.slicerOutputDir;
    if (preExe != null || preOut != null) {
      if (mounted) {
        setState(() {
          _exePath = preExe;
          _outputDir = preOut;
          _isDetecting = false;
        });
      }
      return;
    }
    await _detect();
  }

  Future<void> _detect() async {
    setState(() {
      _isDetecting = true;
      _detectError = null;
    });
    try {
      final exe = await _detector.detectExecutable();
      final out = await _detector.detectOutputDirectory();
      if (!mounted) return;
      setState(() {
        _exePath = exe;
        _outputDir = out;
        _isDetecting = false;
      });
      _syncToProvider();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detectError = friendlyError(e);
        _isDetecting = false;
      });
    }
  }

  void _syncToProvider() {
    ref
        .read(onboardingProvider.notifier)
        .setSlicerResult(exePath: _exePath, outputDir: _outputDir);
  }

  Future<void> _browseExe() async {
    const typeGroup = XTypeGroup(
      label: '可执行文件',
      extensions: <String>['exe'],
    );
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null) return;
    setState(() => _exePath = file.path);
    _syncToProvider();
  }

  Future<void> _browseDir() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    setState(() => _outputDir = dir);
    _syncToProvider();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '检测切片软件',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '自动识别 Bambu Studio 安装位置与 G-code 输出目录。检测不到时可手动选择，或跳过此步。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        // 可执行文件
        const _SectionLabel(
          icon: Icons.memory_rounded,
          text: '可执行文件 (bambu-studio.exe)',
        ),
        const SizedBox(height: 6),
        _PathRow(
          isDetecting: _isDetecting,
          path: _exePath,
          placeholder: '未检测到 Bambu Studio',
          onDetect: _detect,
          onBrowse: _browseExe,
          browseLabel: '选择 exe',
        ),
        const SizedBox(height: 18),
        // 输出目录
        const _SectionLabel(icon: Icons.folder_outlined, text: 'G-code 输出目录'),
        const SizedBox(height: 6),
        _PathRow(
          isDetecting: _isDetecting,
          path: _outputDir,
          placeholder: '未检测到输出目录',
          onDetect: _detect,
          onBrowse: _browseDir,
          browseLabel: '选择目录',
        ),
        if (_detectError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.dangerContainer,
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
            ),
            child: Text(
              '检测出错：$_detectError',
              style: const TextStyle(fontSize: 12, color: AppColors.danger),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '提示：输出目录用于监听切片完成事件，自动统计耗材消耗。可稍后在设置中修改。',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.primary),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  final bool isDetecting;
  final String? path;
  final String placeholder;
  final VoidCallback onDetect;
  final VoidCallback onBrowse;
  final String browseLabel;

  const _PathRow({
    required this.isDetecting,
    required this.path,
    required this.placeholder,
    required this.onDetect,
    required this.onBrowse,
    required this.browseLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          if (isDetecting)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              path != null
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 18,
              color: path != null
                  ? AppColors.success
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path ?? placeholder,
              style: TextStyle(
                fontSize: 12,
                color: path != null
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: isDetecting ? null : onDetect,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('重新检测', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: isDetecting ? null : onBrowse,
            icon: const Icon(Icons.folder_open_rounded, size: 14),
            label: Text(browseLabel, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
