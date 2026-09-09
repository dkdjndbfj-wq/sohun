import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/external/printer/bambu_bind_service.dart';
import '../../data/external/printer/bambu_cloud_client.dart';
import '../../data/external/printer/bambu_cloud_session_store.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/seed/printer_seed.dart';
import '../../providers/database_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/printer_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_select.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/printer_image.dart';
import '../settings/cloud_login_dialog.dart';
import 'printer_certificate_trust_dialog.dart';

enum _AddMode { preset, custom, bambuPin, lanDirect }

/// 添加打印机表单。支持「从预设选择」与「自定义」两种模式。
/// Physical feed sources are configured separately: printer external inputs
/// remain present when AMS units are added; simultaneous use depends on routing.
/// External bindings remain physical records. Mixed AMS
/// generations can have different slot counts (AMS HT is one slot; other
/// Bambu units are four).
///
/// 通过 [showGeneralDialog] 居中弹窗弹出，maxWidth 560，maxHeight 80% 屏高，
/// 入场 scale 0.92→1 + fade（220ms easeOutBack）。
class AddPrinterSheet extends ConsumerStatefulWidget {
  const AddPrinterSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: const Color(0x4D000000), // 半透明遮罩
      transitionDuration: AppCurves.durationModal,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        // 修复：原 CurvedAnimation 未 dispose 造成累积泄漏，改用 AnimatedBuilder。
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = animation.value;
            final curvedScale = AppCurves.curveModal.transform(t);
            final scale = 0.92 + 0.08 * curvedScale;
            final fade = Curves.easeOut.transform(t).clamp(0.0, 1.0);
            return Opacity(
              opacity: fade,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        // 键盘出现时整体上移；高度按可见区域计算保证不被遮挡
        final mq = MediaQuery.of(context);
        final visibleHeight = mq.size.height - mq.viewInsets.bottom;
        // 对话框固定宽度（不超过 560），高度 80% 可见区域
        final dialogWidth = (mq.size.width - AppSpacing.xl * 2).clamp(
          0.0,
          560.0,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: Center(
            child: SizedBox(
              width: dialogWidth,
              height: visibleHeight * 0.8,
              child: GlassCard(
                level: GlassLevel.l3,
                borderRadius: BorderRadius.circular(AppColors.radiusXl),
                padding: EdgeInsets.zero,
                child: const AddPrinterSheet(),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  ConsumerState<AddPrinterSheet> createState() => _AddPrinterSheetState();
}

class _AddPrinterSheetState extends ConsumerState<AddPrinterSheet> {
  _AddMode _mode = _AddMode.preset;
  PrinterPreset? _selectedPreset;
  int _amsCount = 0;
  final List<AmsUnitType> _amsTypes = [];
  int _customExternalInputCount = 1;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _brandController = TextEditingController();
  final _modelController = TextEditingController();
  final _imageController = TextEditingController();
  int _customMaxAms = 0;

  // PIN 码绑定相关
  final _pinController = TextEditingController();
  bool _isBinding = false;
  final List<String> _bindLogs = [];
  BambuBindPrerequisites? _prereq;

  // LAN 直连相关
  final _lanIpController = TextEditingController();
  final _lanAccessController = TextEditingController();
  final _lanSerialController = TextEditingController();
  final _lanNameController = TextEditingController();
  String _lanModel = 'P1S';
  double _lanNozzleDiameter = 0.4;
  String? _lanIpError;

  @override
  void dispose() {
    _nameController.dispose();
    _brandController.dispose();
    _modelController.dispose();
    _imageController.dispose();
    _pinController.dispose();
    _lanIpController.dispose();
    _lanAccessController.dispose();
    _lanSerialController.dispose();
    _lanNameController.dispose();
    super.dispose();
  }

  int get _externalInputCount {
    if (_mode == _AddMode.preset && _selectedPreset != null) {
      return _selectedPreset!.externalInputsForAms(_amsCount);
    }
    return _customExternalInputCount;
  }

  List<AmsUnitType> get _resolvedAmsTypes {
    final defaultType = _selectedPreset?.defaultAmsType ?? AmsUnitType.unknown;
    return List.generate(
      _amsCount,
      (index) => index < _amsTypes.length ? _amsTypes[index] : defaultType,
      growable: false,
    );
  }

  PrinterFeedConfiguration get _feedConfiguration {
    final preset = _selectedPreset;
    return PrinterFeedConfiguration(
      externalInputCount: _externalInputCount,
      amsTypes: _resolvedAmsTypes,
      channelsPerGenericSystem: preset?.channelsPerAms ?? 4,
      amsLiteMixed: preset?.amsLiteCanCombineWithStandard ?? false,
      externalCanCoexistWithAms: preset?.externalCanCoexistWithAms ?? false,
      bambuLabels: preset?.isBambu ?? false,
    );
  }

  int get _channelCount => _feedConfiguration.channelCount;

  void _setAmsCount(int count) {
    final defaultType = _selectedPreset?.defaultAmsType ?? AmsUnitType.unknown;
    setState(() {
      _amsCount = count;
      while (_amsTypes.length < count) {
        _amsTypes.add(defaultType);
      }
      if (_amsTypes.length > count) {
        _amsTypes.removeRange(count, _amsTypes.length);
      }
      // A2L 的官方布局是 4 台常规 AMS + 1 台 AMS Lite。达到第 5 台时
      // 自动把新增单元设为 Lite，避免生成固件不支持的第 5 台常规 AMS。
      final preset = _selectedPreset;
      if (preset?.amsLiteCanCombineWithStandard == true &&
          count > preset!.maxAmsCount &&
          _amsTypes.isNotEmpty) {
        _amsTypes[count - 1] = AmsUnitType.amsLite;
      }
      if (preset != null && !preset.validateAmsTypes(_amsTypes)) {
        _amsTypes
          ..clear()
          ..addAll(preset.defaultAmsTypes(count));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 暗色模式色值切换
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final dividerColor = isDark ? AppColors.dividerDark : AppColors.divider;

    return Column(
      children: [
        // 标题 + 模式切换
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '添加打印机',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '选择机型后可单独配置多色系统',
                style: TextStyle(fontSize: 12, color: textSecondary),
              ),
              const SizedBox(height: 12),
              GlassSegmentedSurface(
                child: SegmentedButton<_AddMode>(
                  segments: const [
                    ButtonSegment(value: _AddMode.preset, label: Text('从预设选择')),
                    ButtonSegment(value: _AddMode.custom, label: Text('自定义')),
                    ButtonSegment(
                      value: _AddMode.bambuPin,
                      label: Text('PIN码绑定'),
                    ),
                    ButtonSegment(
                      value: _AddMode.lanDirect,
                      label: Text('LAN直连'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) {
                    setState(() => _mode = s.first);
                    if (_mode == _AddMode.bambuPin) {
                      _checkBindPrerequisites();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        Divider(color: dividerColor, height: 1),
        Expanded(
          child: _mode == _AddMode.preset
              ? _buildPreset()
              : _mode == _AddMode.custom
              ? _buildCustom()
              : _mode == _AddMode.bambuPin
              ? _buildBambuPin()
              : _buildLanDirect(),
        ),
        Divider(color: dividerColor, height: 1),
        _mode == _AddMode.bambuPin
            ? _buildBambuPinBottomBar()
            : _mode == _AddMode.lanDirect
            ? _buildLanDirectBottomBar()
            : _buildBottomBar(),
      ],
    );
  }

  Widget _buildPreset() {
    final grouped = ref.watch(printerPresetsProvider);
    final brands = grouped.keys.toList()..sort();
    final width = MediaQuery.sizeOf(context).width;
    // 弹窗内最多 4 列（弹窗宽度上限 560，5 列会过挤）；窄屏 3 列
    final crossCount = width < 480 ? 3 : 4;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        for (final brand in brands) ...[
          // 品牌标题
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(
              brand,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
          ),
          // 该品牌的网格
          GridView.count(
            crossAxisCount: crossCount,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // 宽高比 0.8 让卡片接近正方形偏竖
            childAspectRatio: 0.82,
            children: [
              for (final p in grouped[brand]!)
                _PresetTile(
                  preset: p,
                  selected: _selectedPreset == p,
                  onTap: () => setState(() {
                    _selectedPreset = p;
                    _amsCount = 0;
                    _amsTypes.clear();
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildCustom() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: [
          // 品牌：保留 TextFormField 以参与 Form 校验
          TextFormField(
            controller: _brandController,
            decoration: _inputDecoration('品牌 *', '如 Bambu Lab'),
            validator: (v) => (v == null || v.trim().isEmpty) ? '请输入品牌' : null,
          ),
          const SizedBox(height: 12),
          // 型号：保留 TextFormField 以参与 Form 校验
          TextFormField(
            controller: _modelController,
            decoration: _inputDecoration('型号 *', '如 X1'),
            validator: (v) => (v == null || v.trim().isEmpty) ? '请输入型号' : null,
          ),
          const SizedBox(height: 16),
          _ExternalFeedConfig(
            count: _customExternalInputCount,
            onChanged: (value) =>
                setState(() => _customExternalInputCount = value),
          ),
          const SizedBox(height: 12),
          _AmsConfig(
            amsCount: _amsCount,
            maxAms: _customMaxAms,
            channelsPerAms: 4,
            amsTypes: _resolvedAmsTypes,
            isBambu: false,
            onChanged: _setAmsCount,
            onTypeChanged: (index, type) =>
                setState(() => _amsTypes[index] = type),
            onMaxAmsChanged: (v) => setState(() {
              _customMaxAms = v;
              if (_amsCount > v) {
                _amsCount = v;
                _amsTypes.removeRange(v, _amsTypes.length);
              }
            }),
          ),
          const SizedBox(height: 12),
          // 图片路径：AppInput 替换 TextField
          AppInput(
            label: '图片路径（可选）',
            hint: '留空使用品牌 fallback',
            controller: _imageController,
          ),
        ],
      ),
    );
  }

  /// 统一输入框样式：浅灰边框 + Indigo 聚焦边框。
  /// 用于品牌 / 型号 TextFormField（参与 Form 校验，需保留 TextFormField 形态）。
  /// 自动适配暗色模式。
  InputDecoration _inputDecoration(String label, String hint) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(
        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
      ),
      hintStyle: TextStyle(
        color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: isDark ? AppColors.outlineDark : AppColors.outline,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.primary, width: 1.5),
      ),
    );
  }

  Widget _buildBottomBar() {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .62,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 名称输入（统一两种模式）：AppInput 替换 TextField
              AppInput(
                label: '打印机名称（可选）',
                hint: '如 工位1、备用机',
                controller: _nameController,
              ),
              const SizedBox(height: 12),
              // 预设模式：选中后显示 AMS 配置
              if (_mode == _AddMode.preset && _selectedPreset != null) ...[
                _ExternalFeedConfig(count: _externalInputCount),
                const SizedBox(height: 10),
                _AmsConfig(
                  amsCount: _amsCount,
                  maxAms: _selectedPreset!.maxConfiguredAmsUnits,
                  channelsPerAms: _selectedPreset!.channelsPerAms,
                  amsTypes: _resolvedAmsTypes,
                  isBambu: _selectedPreset!.isBambu,
                  amsLiteCanCombineWithStandard:
                      _selectedPreset!.amsLiteCanCombineWithStandard,
                  supportedTypes: AmsUnitType.values
                      .where(_selectedPreset!.supportsAmsType)
                      .toList(),
                  onChanged: _setAmsCount,
                  onTypeChanged: (index, type) =>
                      setState(() => _amsTypes[index] = type),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedPreset!.feedCapabilitySummary,
                  style: const TextStyle(fontSize: 11),
                ),
                if (_selectedPreset!.amsConfigurationError(_resolvedAmsTypes)
                    case final error?)
                  Text(
                    error,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                const Text(
                  '外挂位保存装料记录；连接设备后，按 AMS 实际接入的喷头显示可用路径。',
                  style: TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 12),
              ],
              _ChannelPreview(
                externalInputCount: _externalInputCount,
                amsChannelCount: _feedConfiguration.amsChannelCount,
              ),
              const SizedBox(height: 12),
              // 添加按钮：AppButton primary 全宽
              SizedBox(
                width: double.infinity,
                child: AppButton(
                  label: '添加',
                  icon: Builder(
                    builder: (context) => BambuIcon(
                      name: 'add_filament',
                      size: 18,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : AppColors.onPrimary,
                      applyColorFilter: true,
                    ),
                  ),
                  onPressed: _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final dao = ref.read(printerDaoProvider);
    final name = _nameController.text.trim();
    if (_mode == _AddMode.preset) {
      final p = _selectedPreset;
      if (p == null) {
        showSnack(context, '请先选择一个型号', error: true);
        return;
      }
      final configError = p.amsConfigurationError(_resolvedAmsTypes);
      if (configError != null) {
        showSnack(context, configError, error: true);
        return;
      }
      await dao.addPrinterWithFeedConfiguration(
        brand: p.brand,
        model: p.model,
        feedConfiguration: _feedConfiguration,
        imageAsset: p.imageAsset,
        isCustomImage: false,
        name: name.isEmpty ? null : name,
      );
    } else {
      FocusScope.of(context).unfocus();
      if (!_formKey.currentState!.validate()) return;
      final brand = _brandController.text.trim();
      final model = PrinterDao.normalizeModel(_modelController.text.trim());
      final img = _imageController.text.trim();
      final customFeed = PrinterFeedConfiguration(
        externalInputCount: _customExternalInputCount,
        amsTypes: _resolvedAmsTypes,
        channelsPerGenericSystem: 4,
        bambuLabels:
            brand.contains('拓竹') || brand.toLowerCase().contains('bambu'),
      );
      await dao.addPrinterWithFeedConfiguration(
        brand: brand,
        model: model,
        feedConfiguration: customFeed,
        imageAsset: img.isEmpty ? null : img,
        isCustomImage: img.isNotEmpty,
        name: name.isEmpty ? null : name,
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
      showSnack(context, '已添加打印机（$_channelCount 个物理供料位）');
    }
  }

  // ============ PIN 码绑定拓竹打印机 ============

  Future<void> _checkBindPrerequisites() async {
    final prereq = await BambuBindService.checkPrerequisites();
    if (mounted) setState(() => _prereq = prereq);
  }

  Widget _buildBambuPin() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        // 说明卡片
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.primary.withValues(alpha: 0.15)
                : AppColors.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'PIN 码绑定拓竹打印机',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '1. 在打印机屏幕：设置 → 网络 → WLAN → PIN 码\n'
                '2. 输入 6 位 PIN 码并点击绑定\n'
                '3. 绑定成功后自动同步到云端设备列表\n'
                '4. 需要已登录拓竹云账号',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 前置条件检查
        if (_prereq == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          // 前置条件状态
          ..._buildPrerequisiteItems(),
          const SizedBox(height: 16),
          if (_prereq!.isReady) ...[
            // PIN 码输入
            AppInput(
              label: 'PIN 码（6 位字母数字）',
              hint: '如 BR2DDU',
              controller: _pinController,
              keyboardType: TextInputType.text,
              inputFormatters: [
                LengthLimitingTextInputFormatter(6),
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              ],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
          ],
          // 绑定日志
          if (_bindLogs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _bindLogs.length,
                itemBuilder: (context, i) => Text(
                  _bindLogs[i],
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: isDark ? Colors.greenAccent : Colors.green[800],
                  ),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  List<Widget> _buildPrerequisiteItems() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    final items = <Widget>[];
    final checks = [('已登录拓竹云账号', _prereq!.loggedIn)];

    for (final (label, ok) in checks) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Icon(
                ok ? Icons.check_circle_rounded : Icons.cancel,
                size: 16,
                color: ok ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontSize: 13, color: textSecondary)),
            ],
          ),
        ),
      );
    }

    if (!_prereq!.isReady) {
      items.add(const SizedBox(height: 8));
      for (final missing in _prereq!.missingItems) {
        items.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '• $missing',
              style: TextStyle(fontSize: 12, color: Colors.orange[700]),
            ),
          ),
        );
      }
      // 未登录时提供"去登录"快捷入口
      items.add(const SizedBox(height: 12));
      items.add(
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => CloudLoginDialog.show(context),
            icon: const Icon(Icons.login, size: 16),
            label: const Text('去登录拓竹云账号'),
          ),
        ),
      );
    }

    return items;
  }

  Widget _buildBambuPinBottomBar() {
    final isReady = _prereq?.isReady ?? false;
    final pin = _pinController.text.trim();
    final canBind = isReady && !_isBinding && pin.length == 6;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: AppButton(
          label: _isBinding ? '绑定中...' : '绑定打印机',
          icon: Icon(_isBinding ? Icons.hourglass_top : Icons.link),
          onPressed: canBind ? _doBind : null,
        ),
      ),
    );
  }

  Future<void> _doBind() async {
    final pin = _pinController.text.trim().toUpperCase();
    if (pin.length != 6) {
      showSnack(context, 'PIN 码必须是 6 位', error: true);
      return;
    }

    setState(() {
      _isBinding = true;
      _bindLogs.clear();
    });

    final result = await BambuBindService.bindWithPin(
      pin: pin,
      onLog: (log) {
        if (mounted) {
          setState(() => _bindLogs.add(log));
        }
      },
    );

    if (!mounted) return;

    setState(() => _isBinding = false);

    if (result.success) {
      // 绑定成功，尝试同步云端设备列表
      setState(() => _bindLogs.add('正在同步设备列表...'));
      await _syncCloudDevices();
      if (mounted) {
        setState(() => _bindLogs.add('同步完成！'));
        showSnack(context, '打印机绑定成功！');
        Navigator.of(context).pop();
      }
    } else {
      final message = friendlyError(result.error ?? '绑定失败');
      showSnack(context, '绑定失败：$message', error: true);
      setState(() => _bindLogs.add('错误：$message'));
    }
  }

  /// 绑定成功后同步云端设备列表到本地
  Future<void> _syncCloudDevices() async {
    try {
      final session = await BambuCloudSessionStore.loadSession();
      if (session == null) {
        setState(() => _bindLogs.add('  (未找到活跃账户，跳过同步)'));
        return;
      }

      final devices = await BambuCloudClient.getDeviceList(session);
      final dao = ref.read(printerDaoProvider);
      for (final dev in devices) {
        await dao.upsertCloudDevice(dev);
      }
      setState(() => _bindLogs.add('  已同步 ${devices.length} 台设备'));
    } catch (e) {
      if (mounted) {
        setState(() => _bindLogs.add('  同步失败：${friendlyError(e)}'));
      }
    }
  }

  // ============ LAN 直连配置 ============

  Widget _buildLanDirect() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        // 说明卡片
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.primary.withValues(alpha: 0.15)
                : AppColors.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lan_outlined, size: 18, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    'LAN 直连配置',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '直接通过局域网 IP 连接拓竹打印机，无需登录云账号。\n'
                '前提：打印机已开启「局域网访问」模式，且与电脑在同一 WiFi。\n'
                'Access Code 在打印机屏幕：设置 → 网络 → WLAN → 局域网访问码',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppSelect<String>(
          value: _lanModel,
          label: '打印机型号',
          items: PrinterPresets.all
              .where((preset) => preset.brand == '拓竹')
              .map(
                (preset) => DropdownMenuItem(
                  value: preset.model,
                  child: Text(preset.model),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) setState(() => _lanModel = value);
          },
        ),
        const SizedBox(height: 10),
        _ExternalFeedConfig(
          count:
              PrinterPresets.findByModel(
                _lanModel,
                brand: '拓竹',
              )?.externalInputCount ??
              1,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'AMS 数量、代际和槽位会在首次连接后按打印机实际上报自动同步。',
            style: TextStyle(fontSize: 10, color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 12),
        AppSelect<double>(
          value: _lanNozzleDiameter,
          label: '当前安装喷嘴',
          items: const [0.2, 0.4, 0.6, 0.8]
              .map(
                (diameter) => DropdownMenuItem(
                  value: diameter,
                  child: Text('${diameter.toStringAsFixed(1)} mm'),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => _lanNozzleDiameter = value);
            }
          },
        ),
        const SizedBox(height: 12),
        AppInput(
          label: 'IP 地址 *',
          hint: '如 192.168.31.100',
          controller: _lanIpController,
          keyboardType: TextInputType.number,
          errorText: _lanIpError,
          onChanged: (_) => setState(() => _lanIpError = null),
        ),
        const SizedBox(height: 12),
        AppInput(
          label: 'Access Code *',
          hint: '8 位数字（打印机屏幕获取）',
          controller: _lanAccessController,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        AppInput(
          label: '序列号（推荐填写）',
          hint: '15 位 SN，填了才能同步 access code 到切片软件',
          controller: _lanSerialController,
        ),
        const SizedBox(height: 12),
        AppInput(
          label: '名称（可选）',
          hint: '如 客厅打印机',
          controller: _lanNameController,
        ),
      ],
    );
  }

  Widget _buildLanDirectBottomBar() {
    final ip = _lanIpController.text.trim();
    final code = _lanAccessController.text.trim();
    final canSubmit = ip.isNotEmpty && code.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: AppButton(
          label: '添加 LAN 直连',
          icon: Builder(
            builder: (context) => BambuIcon(
              name: 'add_filament',
              size: 18,
              color: IconTheme.of(context).color ?? AppColors.onPrimary,
              applyColorFilter: true,
            ),
          ),
          onPressed: canSubmit ? _submitLanDirect : null,
        ),
      ),
    );
  }

  Future<void> _submitLanDirect() async {
    final ip = _lanIpController.text.trim();
    final accessCode = _lanAccessController.text.trim();
    final serialInput = _lanSerialController.text.trim();
    final nameInput = _lanNameController.text.trim();

    if (ip.isEmpty) {
      setState(() => _lanIpError = '请输入 IP 地址');
      return;
    }
    if (accessCode.isEmpty) {
      showSnack(context, '请输入 Access Code', error: true);
      return;
    }

    // 序列号优先用用户输入，否则用 IP 作为唯一标识
    final serial = serialInput.isNotEmpty ? serialInput : ip;
    final config = PrinterConnectionConfig.lan(
      serial: serial,
      host: ip,
      accessCode: accessCode,
      devProductName: _lanModel,
      installedNozzleDiameter: _lanNozzleDiameter,
      displayName: nameInput.isNotEmpty ? nameInput : null,
    );

    if (!await confirmPrinterCertificateTrust(context, config)) return;
    if (!mounted) return;

    await ref.read(printerConnectionListProvider.notifier).add(config);

    if (mounted) {
      showSnack(context, '已添加 LAN 直连：${nameInput.isNotEmpty ? nameInput : ip}');
      Navigator.of(context).pop();
    }
  }
}

/// 预设型号行：图片 + 名称 + AMS 支持标签。
class _PresetTile extends StatelessWidget {
  final PrinterPreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 选中 / 未选中 背景色与边框色（暗色模式适配）
    final bgColor = selected
        ? AppColors.primaryContainer
        : (isDark ? AppColors.surfaceDark : AppColors.surface);
    final borderColor = selected
        ? AppColors.primary
        : (isDark ? AppColors.outlineDark : AppColors.outline);
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    return Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 打印机图片（占主要空间）
                  Expanded(
                    child: Center(
                      child: PrinterImage(
                        assetPath: preset.imageAsset,
                        brand: preset.brand,
                        size: 80,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 型号名
                  Text(
                    preset.model,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  // 多色系统标签
                  if (preset.supportsAms)
                    Text(
                      preset.feedCapabilitySummary,
                      style: TextStyle(fontSize: 10, color: textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      '${preset.externalInputCount} 个外挂料位',
                      style: TextStyle(fontSize: 10, color: textTertiary),
                    ),
                ],
              ),
            ),
            // 选中标记：右上角对勾
            if (selected)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExternalFeedConfig extends StatelessWidget {
  const _ExternalFeedConfig({required this.count, this.onChanged});

  final int count;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Icon(Icons.input_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '打印机外挂供料',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  count == 0
                      ? '已启用 AMS，不使用外挂料位'
                      : count == 1
                      ? '1 个外挂料位'
                      : '左右 2 个独立外挂料位',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (onChanged != null)
            GlassSegmentedSurface(
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('单')),
                  ButtonSegment(value: 2, label: Text('双')),
                ],
                selected: {count},
                showSelectedIcon: false,
                onSelectionChanged: (value) => onChanged!(value.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            )
          else if (count > 0)
            Text(
              count == 1 ? '单外挂' : '双外挂',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            )
          else
            Text(
              'AMS 专用',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}

/// AMS 数量配置器。步进器选 0~maxAmsCount 个 AMS，附快速选择 0/1/2/4。
class _AmsConfig extends StatelessWidget {
  final int amsCount;
  final int maxAms;
  final int channelsPerAms;
  final List<AmsUnitType> amsTypes;
  final bool isBambu;
  final bool amsLiteCanCombineWithStandard;
  final List<AmsUnitType> supportedTypes;
  final ValueChanged<int> onChanged;
  final void Function(int index, AmsUnitType type) onTypeChanged;
  final ValueChanged<int>? onMaxAmsChanged; // 自定义模式可调上限

  const _AmsConfig({
    required this.amsCount,
    required this.maxAms,
    required this.channelsPerAms,
    required this.amsTypes,
    required this.isBambu,
    this.amsLiteCanCombineWithStandard = false,
    this.supportedTypes = const [
      AmsUnitType.ams,
      AmsUnitType.amsLite,
      AmsUnitType.ams2Pro,
      AmsUnitType.amsHt,
    ],
    required this.onChanged,
    required this.onTypeChanged,
    this.onMaxAmsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final mixedLite =
        isBambu &&
        amsLiteCanCombineWithStandard &&
        amsTypes.any((type) => type == AmsUnitType.amsLite) &&
        amsTypes.any((type) => type != AmsUnitType.amsLite);
    final totalChannels = isBambu
        ? amsTypes.fold<int>(
            0,
            (sum, type) =>
                sum +
                (type == AmsUnitType.amsHt
                    ? 1
                    : type == AmsUnitType.amsLite && mixedLite
                    ? 3
                    : channelsPerAms),
          )
        : amsCount * channelsPerAms;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.palette_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            const Text(
              '多色系统',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            if (maxAms == 0 && onMaxAmsChanged == null)
              const Text(
                '该机型不支持多色系统',
                style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (maxAms > 0 || onMaxAmsChanged != null) ...[
          // AMS 数量步进
          Row(
            children: [
              _AmsStepButton(
                icon: Icons.remove,
                enabled: amsCount > 0,
                onTap: () => onChanged(amsCount - 1),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Column(
                    children: [
                      Text(
                        '$amsCount',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const Text(
                        '组多色系统',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AmsStepButton(
                icon: Icons.add_rounded,
                enabled: amsCount < maxAms,
                onTap: () => onChanged(amsCount + 1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 通道数预览
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: amsCount > 0
                  ? AppColors.primaryContainer
                  : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  amsCount > 0 ? Icons.layers_rounded : Icons.looks_one_rounded,
                  size: 14,
                  color: amsCount > 0
                      ? AppColors.onPrimaryContainer
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  amsCount == 0
                      ? '未连接多色系统'
                      : '$totalChannels 个 AMS 料位（共 $amsCount 台）',
                  style: TextStyle(
                    fontSize: 12,
                    color: amsCount > 0
                        ? AppColors.onPrimaryContainer
                        : AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (isBambu && amsCount > 0) ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = amsCount == 1
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 8) / 2;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var index = 0; index < amsCount; index++)
                      SizedBox(
                        width: itemWidth,
                        child: DropdownButtonFormField<AmsUnitType>(
                          key: ValueKey('$index-${amsTypes[index].name}'),
                          initialValue: amsTypes[index],
                          isDense: true,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: '第 ${index + 1} 台 AMS',
                            border: const OutlineInputBorder(),
                          ),
                          items: supportedTypes
                              .map(
                                (type) => DropdownMenuItem(
                                  value: type,
                                  child: Text(
                                    type == AmsUnitType.amsHt
                                        ? '${type.displayLabel} · 1 槽'
                                        : '${type.displayLabel} · 4 槽',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (type) {
                            if (type != null) onTypeChanged(index, type);
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
          ],
          // 快速选择 0/1/2/4
          if (maxAms >= 2)
            Row(
              children: [
                for (final n in [0, 1, 2, 4])
                  if (n <= maxAms) ...[
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _QuickAmsChip(
                          label: n == 0 ? '无' : '$n 组',
                          selected: amsCount == n,
                          onTap: () => onChanged(n),
                        ),
                      ),
                    ),
                  ],
              ],
            ),
        ],
        // 自定义模式：可选调整最大 AMS 数
        if (onMaxAmsChanged != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                '最大多色系统组数',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const Spacer(),
              for (final n in [0, 1, 2, 4]) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _QuickAmsChip(
                    label: '$n',
                    selected: maxAms == n,
                    onTap: () => onMaxAmsChanged!(n),
                    tiny: true,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// AMS 步进按钮。启用态 Google 蓝底 + 白字，禁用态浅灰。
class _AmsStepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _AmsStepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox.square(
        dimension: 44,
        child: AppGlassButton(
          tooltip: icon == Icons.add_rounded || icon == Icons.add
              ? '增加 AMS'
              : '减少 AMS',
          onPressed: enabled ? onTap : null,
          compact: true,
          minimumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(12),
          child: Icon(icon, size: 18),
        ),
      );
    }
    return Material(
      color: enabled ? AppColors.primary : AppColors.surfaceVariant,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: enabled ? AppColors.primary : AppColors.divider,
              width: 0.5,
            ),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled ? AppColors.onPrimary : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// AMS 快速选择胶囊。选中 Google 蓝底 + 白字，未选中白底灰字。
class _QuickAmsChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool tiny;

  const _QuickAmsChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tiny = false,
  });

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return Semantics(
        selected: selected,
        child: AppGlassButton(
          label: label,
          onPressed: onTap,
          variant: selected
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.quiet,
          compact: true,
          minimumSize: Size(0, tiny ? 26 : 30),
          padding: EdgeInsets.symmetric(
            horizontal: tiny ? 8 : 10,
            vertical: tiny ? 4 : 6,
          ),
          borderRadius: BorderRadius.circular(10),
          child: Text(
            label,
            style: TextStyle(
              fontSize: tiny ? 11 : 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      );
    }
    return Material(
      color: selected ? AppColors.primary : AppColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: tiny ? 8 : 10,
            vertical: tiny ? 4 : 6,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.outline,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: tiny ? 11 : 12,
              color: selected ? AppColors.onPrimary : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 最终物理供料布局预览行。
class _ChannelPreview extends StatelessWidget {
  final int externalInputCount;
  final int amsChannelCount;

  const _ChannelPreview({
    required this.externalInputCount,
    required this.amsChannelCount,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.tune_rounded,
          size: 14,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 6),
        Text(
          amsChannelCount == 0
              ? '供料布局：$externalInputCount 个外挂料位'
              : externalInputCount == 0
              ? '供料布局：仅 $amsChannelCount 个 AMS 料位'
              : '供料布局：$externalInputCount 个外挂 + $amsChannelCount 个 AMS 料位',
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
