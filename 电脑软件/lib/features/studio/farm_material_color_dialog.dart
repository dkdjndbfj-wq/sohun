import 'package:flutter/material.dart';

import '../../core/utils/color_utils.dart';

/// 颜色模式与颜色值的统一返回结构。
/// colorMode 只允许 solid、multi、gradient，secondaryHex 用于多色/渐变的辅助色。
class FarmMaterialColorValue {
  const FarmMaterialColorValue({
    required this.hex,
    this.name,
    this.colorMode = 'solid',
    this.secondaryHex,
  });

  final String hex;
  final String? name;
  final String colorMode;
  final String? secondaryHex;
}

class FarmMaterialColorField extends StatefulWidget {
  const FarmMaterialColorField({
    super.key,
    required this.hexController,
    required this.nameController,
    this.modeController,
    this.secondaryHexController,
    this.label = '耗材颜色',
    this.dense = false,
  });

  final TextEditingController hexController;
  final TextEditingController nameController;
  final TextEditingController? modeController;
  final TextEditingController? secondaryHexController;
  final String label;
  final bool dense;

  @override
  State<FarmMaterialColorField> createState() => _FarmMaterialColorFieldState();
}

class _FarmMaterialColorFieldState extends State<FarmMaterialColorField> {
  @override
  void initState() {
    super.initState();
    _addListeners(widget);
  }

  void _addListeners(FarmMaterialColorField target) {
    target.hexController.addListener(_refresh);
    target.nameController.addListener(_refresh);
    target.modeController?.addListener(_refresh);
    target.secondaryHexController?.addListener(_refresh);
  }

  void _removeListeners(FarmMaterialColorField target) {
    target.hexController.removeListener(_refresh);
    target.nameController.removeListener(_refresh);
    target.modeController?.removeListener(_refresh);
    target.secondaryHexController?.removeListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant FarmMaterialColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hexController != widget.hexController ||
        oldWidget.nameController != widget.nameController ||
        oldWidget.modeController != widget.modeController ||
        oldWidget.secondaryHexController != widget.secondaryHexController) {
      _removeListeners(oldWidget);
      _addListeners(widget);
    }
  }

  @override
  void dispose() {
    _removeListeners(widget);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hex = _normalizedHex(widget.hexController.text) ?? '#FFFFFF';
    final name = widget.nameController.text.trim();
    final mode = _normalizedMode(widget.modeController?.text);
    final secondary =
        _normalizedHex(widget.secondaryHexController?.text ?? '') ?? '#FFFFFF';
    final swatch = mode == 'solid'
        ? BoxDecoration(
            color: ColorUtils.fromHex(hex),
            shape: BoxShape.circle,
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          )
        : BoxDecoration(
            gradient: LinearGradient(
              colors: [ColorUtils.fromHex(hex), ColorUtils.fromHex(secondary)],
            ),
            shape: BoxShape.circle,
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          );
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final selected = await showFarmMaterialColorDialog(
          context,
          initialHex: hex,
          initialName: name,
          initialColorMode: mode,
          initialSecondaryHex: secondary,
        );
        if (selected == null) return;
        widget.hexController.text = selected.hex;
        widget.nameController.text = selected.name ?? '';
        widget.modeController?.text = selected.colorMode;
        if (widget.secondaryHexController != null) {
          widget.secondaryHexController!.text = selected.secondaryHex ?? '';
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: widget.label,
          isDense: widget.dense,
          suffixIcon: const Icon(Icons.palette_outlined, size: 18),
        ),
        child: Row(
          children: [
            Container(width: 20, height: 20, decoration: swatch),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name.isEmpty ? hex : '$name · $hex',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (mode != 'solid')
              Text(
                mode == 'gradient' ? '渐变' : '多色',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }
}

Future<FarmMaterialColorValue?> showFarmMaterialColorDialog(
  BuildContext context, {
  String initialHex = '#FFFFFF',
  String initialName = '',
  String initialColorMode = 'solid',
  String? initialSecondaryHex,
}) async {
  final hex = TextEditingController(
    text: _normalizedHex(initialHex) ?? '#FFFFFF',
  );
  final name = TextEditingController(text: initialName);
  final secondaryHex = TextEditingController(
    text: _normalizedHex(initialSecondaryHex ?? '') ?? '#FFFFFF',
  );
  var hsv = HSVColor.fromColor(ColorUtils.fromHex(hex.text));
  var mode = _normalizedMode(initialColorMode);
  String? error;

  final result = await showDialog<FarmMaterialColorValue>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final preview = _normalizedHex(hex.text) ?? '#FFFFFF';
        final secondaryPreview = _normalizedHex(secondaryHex.text) ?? '#FFFFFF';

        void updateHsv(HSVColor next) {
          setState(() {
            hsv = next;
            hex.text = ColorUtils.toHex(next.toColor());
            error = null;
          });
        }

        return AlertDialog(
          title: const Text('设置农场耗材颜色'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('颜色模式', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'solid', label: Text('单色')),
                      ButtonSegment(value: 'multi', label: Text('多色')),
                      ButtonSegment(value: 'gradient', label: Text('渐变')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (value) {
                      if (value.isNotEmpty) setState(() => mode = value.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('常用颜色', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in _farmPalette)
                        Tooltip(
                          message: option.name ?? option.hex,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () {
                              name.text = option.name ?? '';
                              updateHsv(HSVColor.fromColor(
                                ColorUtils.fromHex(option.hex),
                              ));
                            },
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: ColorUtils.fromHex(option.hex),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: preview == option.hex
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                  width: preview == option.hex ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('自由调色', style: Theme.of(context).textTheme.labelLarge),
                  _FarmColorSlider(
                    key: const ValueKey('farm-color-hue-slider'),
                    label: '色相',
                    valueLabel: '${hsv.hue.round()}°',
                    value: hsv.hue,
                    max: 360,
                    gradient: const LinearGradient(colors: [
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ]),
                    onChanged: (value) => updateHsv(hsv.withHue(value)),
                  ),
                  _FarmColorSlider(
                    key: const ValueKey('farm-color-saturation-slider'),
                    label: '饱和度',
                    valueLabel: '${(hsv.saturation * 100).round()}%',
                    value: hsv.saturation,
                    gradient: LinearGradient(colors: [
                      hsv.withSaturation(0).toColor(),
                      hsv.withSaturation(1).toColor(),
                    ]),
                    onChanged: (value) => updateHsv(hsv.withSaturation(value)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: ColorUtils.fromHex(preview),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('farm-color-hex-field'),
                          controller: hex,
                          decoration: const InputDecoration(
                            labelText: '主色 HEX',
                            hintText: '#FFFFFF',
                          ),
                          onChanged: (value) {
                            final normalized = _normalizedHex(value);
                            setState(() {
                              error = null;
                              if (normalized != null) {
                                hsv = HSVColor.fromColor(
                                  ColorUtils.fromHex(normalized),
                                );
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: name,
                          decoration: const InputDecoration(labelText: '颜色名称'),
                        ),
                      ),
                    ],
                  ),
                  if (mode != 'solid') ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: ColorUtils.fromHex(secondaryPreview),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const ValueKey(
                              'farm-secondary-color-hex-field',
                            ),
                            controller: secondaryHex,
                            decoration: const InputDecoration(
                              labelText: '辅助色 HEX',
                              hintText: '#FFFFFF',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final normalized = _normalizedHex(hex.text);
                final normalizedSecondary = _normalizedHex(secondaryHex.text);
                if (normalized == null ||
                    (mode != 'solid' && normalizedSecondary == null)) {
                  setState(() => error = '颜色必须是 #RRGGBB 格式');
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  FarmMaterialColorValue(
                    hex: normalized,
                    name: name.text.trim().isEmpty ? null : name.text.trim(),
                    colorMode: mode,
                    secondaryHex: mode == 'solid' ? null : normalizedSecondary,
                  ),
                );
              },
              child: const Text('使用此颜色'),
            ),
          ],
        );
      },
    ),
  );
  Future<void>.delayed(kThemeAnimationDuration * 2, () {
    hex.dispose();
    name.dispose();
    secondaryHex.dispose();
  });
  return result;
}

class _FarmColorSlider extends StatelessWidget {
  const _FarmColorSlider({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.gradient,
    required this.onChanged,
    this.max = 1,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double max;
  final LinearGradient gradient;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              Text(valueLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          SizedBox(
            height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 10,
                  right: 10,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                        gradient: gradient,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: scheme.outlineVariant)),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 10,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 8, elevation: 2),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 15),
                  ),
                  child: Slider(
                      value: value.clamp(0, max),
                      max: max,
                      onChanged: onChanged),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _normalizedMode(String? value) {
  final mode = value?.trim().toLowerCase();
  return mode == 'multi' || mode == 'gradient' ? mode! : 'solid';
}

String? _normalizedHex(String value) {
  final raw = value.trim().toUpperCase();
  final normalized = raw.startsWith('#') ? raw : '#$raw';
  return RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalized) ? normalized : null;
}

const _farmPalette = <FarmMaterialColorValue>[
  FarmMaterialColorValue(hex: '#FFFFFF', name: '白色'),
  FarmMaterialColorValue(hex: '#D9D9D9', name: '浅灰'),
  FarmMaterialColorValue(hex: '#7A7A7A', name: '灰色'),
  FarmMaterialColorValue(hex: '#111111', name: '黑色'),
  FarmMaterialColorValue(hex: '#FF3B30', name: '红色'),
  FarmMaterialColorValue(hex: '#FF8A00', name: '橙色'),
  FarmMaterialColorValue(hex: '#FFD60A', name: '黄色'),
  FarmMaterialColorValue(hex: '#00B42A', name: '绿色'),
  FarmMaterialColorValue(hex: '#00C7BE', name: '青色'),
  FarmMaterialColorValue(hex: '#007AFF', name: '蓝色'),
  FarmMaterialColorValue(hex: '#5856D6', name: '靛色'),
  FarmMaterialColorValue(hex: '#AF52DE', name: '紫色'),
  FarmMaterialColorValue(hex: '#FF2D55', name: '粉色'),
  FarmMaterialColorValue(hex: '#8B5A2B', name: '棕色'),
  FarmMaterialColorValue(hex: '#E6D5B8', name: '米色'),
  FarmMaterialColorValue(hex: '#B87333', name: '铜色'),
];
