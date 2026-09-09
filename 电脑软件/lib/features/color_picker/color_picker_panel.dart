import 'package:flutter/material.dart';

import '../../core/theme/glass_button_theme.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/color_utils.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_glass_button.dart';
import '../../widgets/glass_card.dart';

/// 颜色自定义面板。CRMEB 风格：白色卡片 + Indigo 强调 + 清晰字体层次。
/// 可作为 ModalBottomSheet 弹出（show 方法返回结果），也可内嵌使用（onChange 实时回调）。
class ColorPickerPanel extends StatefulWidget {
  final Color? initial;
  final String? initialName;

  /// Desktop dialogs use a small palette; custom sliders are revealed on demand.
  final bool compact;

  /// 实时颜色变化回调。父组件可据此实时预览，无需等待确认。
  final ValueChanged<({Color color, String name})>? onChange;

  const ColorPickerPanel({
    super.key,
    this.initial,
    this.initialName,
    this.compact = false,
    this.onChange,
  });

  /// 弹出颜色选择面板，返回选择的颜色与名称；用户取消返回 null。
  static Future<({Color color, String name})?> show(
    BuildContext context, {
    Color? initial,
    String? initialName,
    bool compact = false,
  }) {
    if (compact) {
      return showDialog<({Color color, String name})>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, maxHeight: 560),
            child: GlassCard(
              level: GlassLevel.l3,
              padding: EdgeInsets.zero,
              child: ColorPickerPanel(
                initial: initial,
                initialName: initialName,
                compact: true,
              ),
            ),
          ),
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<({Color color, String name})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: isDark ? AppColors.surfaceDark : AppColors.surface,
      builder: (ctx) =>
          ColorPickerPanel(initial: initial, initialName: initialName),
    );
  }

  @override
  State<ColorPickerPanel> createState() => _ColorPickerPanelState();
}

class _ColorPickerPanelState extends State<ColorPickerPanel> {
  late HSVColor _hsv;
  late TextEditingController _hexController;
  late TextEditingController _nameController;
  bool _customColor = false;

  // 10 个预设色块（横向滚动）：红/橙/黄/绿/青/蓝/紫/粉/白/黑
  static const List<({String name, String hex})> _presets = [
    (name: '红', hex: '#F44336'),
    (name: '橙', hex: '#FF9800'),
    (name: '黄', hex: '#FFEB3B'),
    (name: '绿', hex: '#4CAF50'),
    (name: '青', hex: '#00BCD4'),
    (name: '蓝', hex: '#1A73E8'),
    (name: '紫', hex: '#9C27B0'),
    (name: '粉', hex: '#E91E63'),
    (name: '白', hex: '#FFFFFF'),
    (name: '黑', hex: '#000000'),
  ];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial ?? Colors.white;
    _hsv = HSVColor.fromColor(initial);
    _hexController = TextEditingController(text: ColorUtils.toHex(initial));
    _nameController = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _hexController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  // 滑块/预设变化时同步颜色，自动刷新 HEX 文本，并通知父组件。
  void _updateColor(HSVColor next) {
    setState(() {
      _hsv = next;
      _hexController.text = ColorUtils.toHex(next.toColor());
    });
    widget.onChange?.call((
      color: next.toColor(),
      name: _nameController.text.trim(),
    ));
  }

  void _onNameChanged(String input) {
    setState(() {});
    widget.onChange?.call((color: _hsv.toColor(), name: input.trim()));
  }

  void _selectPreset(String hex) {
    final color = ColorUtils.fromHex(hex);
    _nameController.text = _presets.firstWhere((p) => p.hex == hex).name;
    _updateColor(HSVColor.fromColor(color));
  }

  void _confirm() {
    Navigator.of(
      context,
    ).pop((color: _hsv.toColor(), name: _nameController.text.trim()));
  }

  // CRMEB 风格输入框主题：浅灰填充 + 8px 圆角 + Indigo 聚焦边框
  // P1 修复：暗色模式适配
  InputDecorationTheme fieldTheme(bool isDark) => InputDecorationTheme(
    filled: true,
    fillColor: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
    labelStyle: TextStyle(
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
      fontSize: 13,
    ),
    hintStyle: TextStyle(
      color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
      fontSize: 14,
    ),
    floatingLabelStyle: TextStyle(
      color: AppColors.primary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: BorderSide(
        color: isDark ? AppColors.dividerDark : AppColors.border,
        width: 1,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: BorderSide(color: AppColors.primary, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.compact) return _compactPanel(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final currentColor = _hsv.toColor();
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Theme(
          data: Theme.of(
            context,
          ).copyWith(inputDecorationTheme: fieldTheme(isDark)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标题区：图标徽章 + 标题 + 副标题
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primaryContainer,
                        borderRadius: BorderRadius.circular(AppColors.radiusLg),
                      ),
                      child: Icon(
                        Icons.palette_outlined,
                        color: AppColors.primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '选择颜色',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '点选色板，或滑动调色',
                            style: TextStyle(
                              fontSize: 13,
                              color: textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // 大色块预览
                _PreviewBlock(color: currentColor, name: _nameController.text),
                const SizedBox(height: 20),

                // 色相滑块
                _SliderLabel(
                  label: '色相',
                  value: '${_hsv.hue.toStringAsFixed(0)}°',
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
                _GradientSlider(
                  value: _hsv.hue / 360.0,
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ],
                  ),
                  onChanged: (v) => _updateColor(_hsv.withHue(v * 360.0)),
                ),
                const SizedBox(height: 16),

                // 饱和度和明度均可调，不需要手输颜色代码。
                _SliderLabel(
                  label: '饱和度',
                  value: '${(_hsv.saturation * 100).toStringAsFixed(0)}%',
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
                _GradientSlider(
                  value: _hsv.saturation,
                  gradient: LinearGradient(
                    colors: [
                      _hsv.withSaturation(0.0).toColor(),
                      _hsv.withSaturation(1.0).toColor(),
                    ],
                  ),
                  onChanged: (v) => _updateColor(_hsv.withSaturation(v)),
                ),
                const SizedBox(height: 16),
                _SliderLabel(
                  label: '明度',
                  value: '${(_hsv.value * 100).toStringAsFixed(0)}%',
                  isDark: isDark,
                ),
                const SizedBox(height: 8),
                _GradientSlider(
                  value: _hsv.value,
                  gradient: LinearGradient(
                    colors: [Colors.black, _hsv.withValue(1).toColor()],
                  ),
                  onChanged: (v) => _updateColor(_hsv.withValue(v)),
                ),
                const SizedBox(height: 20),

                // HEX 只读展示（由滑块/预设自动生成，不可手输）
                TextField(
                  controller: _hexController,
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'HEX（自动生成）',
                    suffixIcon: Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  style: TextStyle(color: textSecondary),
                ),
                const SizedBox(height: 12),

                // 颜色名称输入框
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '颜色名称',
                    hintText: '如：珍珠白、哑光黑',
                  ),
                  style: TextStyle(color: textPrimary),
                  onChanged: _onNameChanged,
                ),
                const SizedBox(height: 20),

                // 预设色板（横向滚动）
                _SliderLabel(label: '预设', value: '', isDark: isDark),
                const SizedBox(height: 10),
                SizedBox(
                  height: 44,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < _presets.length; i++) ...[
                          _PresetSwatch(
                            hex: _presets[i].hex,
                            name: _presets[i].name,
                            selected:
                                ColorUtils.toHex(currentColor) ==
                                _presets[i].hex,
                            onTap: () => _selectPreset(_presets[i].hex),
                          ),
                          if (i < _presets.length - 1)
                            const SizedBox(width: 12),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // 操作按钮：取消（描边）+ 确认（AppButton primary）
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: glassButtonStyle(
                          context,
                          OutlinedButton.styleFrom(
                            foregroundColor: textSecondary,
                            side: BorderSide(
                              color: isDark
                                  ? AppColors.outlineDark
                                  : AppColors.outline,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppColors.radiusMd,
                              ),
                            ),
                          ),
                          variant: AppGlassButtonVariant.secondary,
                        ),
                        child: const Text(
                          '取消',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppButton(
                        label: '确认',
                        icon: const Icon(Icons.check_rounded),
                        onPressed: _confirm,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactPanel(BuildContext context) {
    final theme = Theme.of(context);
    final color = _hsv.toColor();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择颜色', style: theme.textTheme.titleMedium),
          const SizedBox(height: 14),
          Row(
            children: [
              Tooltip(
                message: ColorUtils.toHex(color),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '颜色名称',
                    isDense: true,
                  ),
                  onChanged: _onNameChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (var row = 0; row < 2; row++) ...[
            Row(
              children: [
                for (final preset in _presets.skip(row * 5).take(5))
                  Expanded(
                    child: Center(
                      child: _PresetSwatch(
                        hex: preset.hex,
                        name: preset.name,
                        selected: ColorUtils.toHex(color) == preset.hex,
                        onTap: () => _selectPreset(preset.hex),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          AppGlassButton(
            label: '自定义调色',
            compact: true,
            variant: AppGlassButtonVariant.quiet,
            icon: Icon(
              _customColor
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 18,
            ),
            onPressed: () => setState(() => _customColor = !_customColor),
          ),
          if (_customColor) ...[
            const SizedBox(height: 10),
            _compactSlider('色相', _hsv.hue / 360, const [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              Color(0xFFFF00FF),
              Color(0xFFFF0000),
            ], (value) => _updateColor(_hsv.withHue(value * 360))),
            _compactSlider(
              '饱和度',
              _hsv.saturation,
              [
                _hsv.withSaturation(0).toColor(),
                _hsv.withSaturation(1).toColor(),
              ],
              (value) => _updateColor(_hsv.withSaturation(value)),
            ),
            _compactSlider('明度', _hsv.value, [
              Colors.black,
              _hsv.withValue(1).toColor(),
            ], (value) => _updateColor(_hsv.withValue(value))),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: AppGlassButton(
                  label: '取消',
                  compact: true,
                  variant: AppGlassButtonVariant.secondary,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppGlassButton(
                  label: '确认',
                  compact: true,
                  onPressed: _confirm,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactSlider(
    String label,
    double value,
    List<Color> colors,
    ValueChanged<double> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: _GradientSlider(
            value: value,
            gradient: LinearGradient(colors: colors),
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}

/// 大色块预览。根据底色亮度自适应文字颜色，避免白字白底。
class _PreviewBlock extends StatelessWidget {
  final Color color;
  final String name;

  const _PreviewBlock({required this.color, required this.name});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isColorDark = color.computeLuminance() < 0.5;
    // 浅色底用深字（textPrimary），深色底用白字
    final fg = isColorDark ? Colors.white : AppColors.textPrimary;
    final fgSubtle = isColorDark
        ? const Color.fromRGBO(255, 255, 255, 0.85)
        : const Color.fromRGBO(31, 31, 31, 0.7);
    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppColors.radiusXl),
        border: Border.all(
          color: isDark ? AppColors.outlineDark : AppColors.outline,
          width: 1,
        ),
        boxShadow: isDark ? AppColors.shadow1Dark : AppColors.shadow1,
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name.isEmpty ? '未命名颜色' : name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ColorUtils.toHex(color),
            style: TextStyle(fontSize: 13, color: fgSubtle),
          ),
        ],
      ),
    );
  }
}

/// 滑块/区块小标题 + 右侧当前值。
class _SliderLabel extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _SliderLabel({
    required this.label,
    required this.value,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (value.isNotEmpty)
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

/// Material 3 风格渐变滑块。value 范围 0.0~1.0。
/// 轨道用对应颜色的渐变填充，圆形白色拇指带阴影。
class _GradientSlider extends StatelessWidget {
  final double value;
  final LinearGradient gradient;
  final ValueChanged<double> onChanged;

  const _GradientSlider({
    required this.value,
    required this.gradient,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const thumbSize = 28.0;
    const trackHeight = 14.0;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final width = constraints.maxWidth;
        // 拇指中心可移动范围：[thumbSize/2, width - thumbSize/2]
        final usableWidth = width - thumbSize;
        // 拇指左上角 left：value=0 时为 0，value=1 时为 usableWidth
        final left = (value * usableWidth).clamp(0.0, usableWidth);

        // 把 tap/pan 的 x 坐标转换为 0~1 的 value
        double valueFromX(double x) {
          if (usableWidth <= 0) return 0.0;
          return ((x - thumbSize / 2) / usableWidth).clamp(0.0, 1.0);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onChanged(valueFromX(d.localPosition.dx)),
          onPanUpdate: (d) => onChanged(valueFromX(d.localPosition.dx)),
          child: SizedBox(
            height: thumbSize,
            child: Stack(
              children: [
                // 渐变轨道（左右留出拇指半径，使拇指中心始终在轨道上）
                Positioned(
                  left: thumbSize / 2,
                  right: thumbSize / 2,
                  top: (thumbSize - trackHeight) / 2,
                  child: Container(
                    height: trackHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(trackHeight / 2),
                      gradient: gradient,
                    ),
                  ),
                ),
                // 拇指
                Positioned(
                  left: left,
                  top: 0,
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(
                        color: isDark
                            ? AppColors.outlineDark
                            : AppColors.outline,
                        width: 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1F000000),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 预设色块。选中时主题色描边 + 阴影。
class _PresetSwatch extends StatelessWidget {
  final String hex;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _PresetSwatch({
    required this.hex,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = ColorUtils.fromHex(hex);
    return Tooltip(
      message: name,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.outline,
              width: selected ? 3 : 1.5,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.25),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
