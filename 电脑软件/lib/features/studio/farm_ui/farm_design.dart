import 'package:flutter/material.dart';

import '../../../data/database/daos/printer_dao.dart';
import 'farm_theme.dart';

abstract final class FarmIcons {
  static const overview = Icons.space_dashboard_outlined;
  static const production = Icons.account_tree_outlined;
  static const batchProduction = Icons.playlist_play_outlined;
  static const devices = Icons.precision_manufacturing_outlined;
  static const inventory = Icons.inventory_2_outlined;
  static const autoEject = Icons.cleaning_services_outlined;
  static const slicing = Icons.tune_outlined;
  static const orders = Icons.assignment_outlined;
  static const customers = Icons.language_outlined;
  static const finance = Icons.request_quote_outlined;
  static const members = Icons.groups_2_outlined;
  static const audit = Icons.fact_check_outlined;
  static const settings = Icons.settings_outlined;
  static const farm = Icons.factory_outlined;

  static IconData fromLegacyName(String name) => switch (name) {
        'monitor_item_print' || 'printer' => devices,
        'tab_filament_active' || 'filament' => inventory,
        'monitor_item_prediction' => Icons.insights_outlined,
        'monitor_item_cost' => finance,
        'completed' => Icons.check_circle_outline,
        'warning' => Icons.warning_amber_rounded,
        'error' => Icons.error_outline,
        'info' => Icons.info_outline,
        _ => Icons.widgets_outlined,
      };
}

class FarmPageHeader extends StatelessWidget {
  const FarmPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.eyebrow = 'FARM OPERATIONS',
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;
  final String eyebrow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 4,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              copy,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: copy),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: 20),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        );
      },
    );
  }
}

class FarmCommandBar extends StatelessWidget {
  const FarmCommandBar({
    super.key,
    required this.children,
    this.trailing = const [],
  });

  final List<Widget> children;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(FarmPalette.radius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 8),
            ...trailing,
          ],
        ],
      ),
    );
  }
}

class FarmIconButton extends StatelessWidget {
  const FarmIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger
        ? scheme.error
        : selected
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: selected ? scheme.primaryContainer : null,
          foregroundColor: color,
          disabledForegroundColor: scheme.outline,
        ),
        icon: Icon(icon, size: 19),
      ),
    );
  }
}

class FrostPanel extends StatelessWidget {
  const FrostPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.color,
    this.elevated = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final bool elevated;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surface,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: elevated
            ? FarmPalette.shadow(context, elevated: true)
            : null,
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        child: content,
      ),
    );
  }
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final String icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 10),
              Icon(FarmIcons.fromLegacyName(icon), size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              StatusPill(label: 'LIVE', color: color),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: FarmVisual.mono.copyWith(
                    color: scheme.onSurface,
                    fontSize: 23,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 5),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    unit,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Container(
            height: 2,
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A farm-only visual wall: one physical printer always maps to one card.
/// This is deliberately denser and more operational than the personal
/// workspace's inventory presentation.
class FarmPrinterMatrix extends StatelessWidget {
  const FarmPrinterMatrix({
    super.key,
    required this.printers,
    this.onPrinterTap,
  });

  final List<PrinterWithChannels> printers;
  final ValueChanged<PrinterWithChannels>? onPrinterTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('设备矩阵', style: FarmVisual.title(context)),
                    const SizedBox(height: 2),
                    Text(
                      '每台打印机对应一张实时可视化卡片，状态与耗材槽位一眼可见',
                      style: FarmVisual.label(context),
                    ),
                  ],
                ),
              ),
              StatusPill(label: '${printers.length} 台设备', color: scheme.primary),
            ],
          ),
          const SizedBox(height: 14),
          if (printers.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 34),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                children: [
                  Icon(Icons.precision_manufacturing_outlined,
                      size: 34, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text('还没有接入打印机', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 3),
                  Text('添加设备后，这里会按设备数量自动生成可视化卡片',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 390,
                mainAxisExtent: 238,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: printers.length,
              itemBuilder: (context, index) {
                final printer = printers[index];
                return FarmPrinterVisualCard(
                  printer: printer,
                  onTap: onPrinterTap == null
                      ? null
                      : () => onPrinterTap!(printer),
                );
              },
            ),
        ],
      ),
    );
  }
}

class FarmPrinterVisualCard extends StatelessWidget {
  const FarmPrinterVisualCard({
    super.key,
    required this.printer,
    this.onTap,
  });

  final PrinterWithChannels printer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = printer.channels.where((item) => item.isActive).length;
    final configured =
        printer.channels.where((item) => item.consumable != null).length;
    final status = active > 0
        ? ('生产中', FarmPalette.success)
        : configured > 0
            ? ('待机', FarmPalette.info)
            : ('待配置', FarmPalette.warning);
    final name = printer.printer.name?.trim();
    final title = name == null || name.isEmpty ? printer.printer.model : name;
    final body = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
        border: Border.all(
          color: onTap == null ? scheme.outlineVariant : status.$2.withValues(alpha: 0.46),
          width: onTap == null ? 1 : 1.2,
        ),
        boxShadow: FarmPalette.shadow(context, elevated: false),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _FarmStatusLight(color: status.$2, active: active > 0),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
              StatusPill(label: status.$1, color: status.$2),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CustomPaint(
                size: const Size(112, 84),
                painter: _FarmPrinterPainter(
                  accent: status.$2,
                  running: active > 0,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      printer.printer.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      printer.serial == null || printer.serial!.isEmpty
                          ? '本地设备 · ${printer.printer.brand}'
                          : printer.serial!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      active > 0 ? '$active 个槽位正在使用' : '$configured/${printer.printer.channelCount} 个槽位已配置',
                      style: TextStyle(color: status.$2, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var index = 0; index < printer.printer.channelCount; index++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: index == printer.printer.channelCount - 1 ? 0 : 4),
                    child: _FarmChannelBar(
                      channel: index < printer.channels.length ? printer.channels[index] : null,
                      accent: status.$2,
                    ),
                  ),
                ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${printer.printer.channelCount} 通道 · ${printer.printer.brand}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (onTap != null)
                TextButton.icon(
                  onPressed: onTap,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 8)),
                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: const Text('设备详情'),
                ),
            ],
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return Semantics(button: true, label: '$title 设备详情', child: body);
  }
}

/// Pannable and zoomable top-down farm floor. The canvas is intentionally
/// spatial: printers occupy positions instead of being rendered as a table.
class FarmPrinterSpatialCanvas extends StatefulWidget {
  const FarmPrinterSpatialCanvas({
    super.key,
    required this.printers,
    this.onPrinterTap,
  });

  final List<PrinterWithChannels> printers;
  final ValueChanged<PrinterWithChannels>? onPrinterTap;

  @override
  State<FarmPrinterSpatialCanvas> createState() =>
      _FarmPrinterSpatialCanvasState();
}

class _FarmPrinterSpatialCanvasState extends State<FarmPrinterSpatialCanvas> {
  late final TransformationController _transform;

  @override
  void initState() {
    super.initState();
    _transform = TransformationController();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _resetView() => setState(() => _transform.value = Matrix4.identity());

  void _scaleView(double factor) {
    final next = _transform.value.clone()
      ..scaleByDouble(factor, factor, factor, 1);
    _transform.value = next;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = widget.printers.length <= 4
        ? 2
        : widget.printers.length <= 9
            ? 3
            : 4;
    final rows = widget.printers.isEmpty
        ? 1
        : (widget.printers.length / columns).ceil();
    final canvasSize = Size(
      columns * 222.0 + 90,
      rows * 168.0 + 96,
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(FarmPalette.radius),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: FarmPalette.shadow(context, elevated: true),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            InteractiveViewer(
              transformationController: _transform,
              minScale: 0.58,
              maxScale: 2.2,
              boundaryMargin: const EdgeInsets.all(180),
              constrained: false,
              panEnabled: true,
              scaleEnabled: true,
              child: SizedBox(
                width: canvasSize.width,
                height: canvasSize.height,
                child: CustomPaint(
                  painter: _FarmFloorPainter(
                    lineColor: scheme.primary.withValues(alpha: 0.16),
                    laneColor: scheme.primary.withValues(alpha: 0.07),
                    accent: scheme.primary,
                    backgroundColor: scheme.surface,
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 28,
                        top: 22,
                        child: Text(
                          'FARM FLOOR  /  俯视生产空间',
                          style: TextStyle(
                            color: scheme.primary.withValues(alpha: 0.72),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.3,
                          ),
                        ),
                      ),
                      for (var index = 0;
                          index < widget.printers.length;
                          index++)
                        Positioned(
                          left: 28 + (index % columns) * 222,
                          top: 54 + (index ~/ columns) * 168,
                          child: _FarmSpatialPrinterNode(
                            printer: widget.printers[index],
                            onTap: widget.onPrinterTap == null
                                ? null
                                : () => widget.onPrinterTap!(
                                      widget.printers[index],
                                    ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 14,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    '拖动画布 · 滚轮缩放 · 点击设备查看详情',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 14,
              top: 12,
              child: Row(
                children: [
                  _FarmLegendDot(color: FarmPalette.success, label: '生产中'),
                  const SizedBox(width: 10),
                  _FarmLegendDot(color: FarmPalette.info, label: '待机'),
                  const SizedBox(width: 10),
                  _FarmLegendDot(color: FarmPalette.warning, label: '告警'),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: '缩小画布',
                    onPressed: () => _scaleView(0.86),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '重置画布视角',
                    onPressed: _resetView,
                    icon: const Icon(Icons.center_focus_strong_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '放大画布',
                    onPressed: () => _scaleView(1.16),
                    icon: const Icon(Icons.add_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FarmLegendDot extends StatelessWidget {
  const _FarmLegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FarmStatusLight(color: color, active: false),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _FarmSpatialPrinterNode extends StatelessWidget {
  const _FarmSpatialPrinterNode({required this.printer, this.onTap});
  final PrinterWithChannels printer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = printer.channels.where((item) => item.isActive).length;
    final configured = printer.channels.where((item) => item.consumable != null).length;
    final status = active > 0
        ? ('生产中', FarmPalette.success)
        : configured > 0
            ? ('待机', FarmPalette.info)
            : ('空闲', scheme.onSurfaceVariant);
    final title = printer.printer.name?.trim().isNotEmpty == true
        ? printer.printer.name!.trim()
        : printer.printer.model;
    final node = SizedBox(
      width: 210,
      height: 142,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 18,
            top: 28,
            child: CustomPaint(
              size: const Size(130, 100),
              painter: _FarmIsometricPrinterPainter(
                accent: status.$2,
                running: active > 0,
              ),
            ),
          ),
          Positioned(
            left: 126,
            top: 39,
            child: Container(
              width: 82,
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(FarmPalette.controlRadius),
                border: Border.all(color: status.$2.withValues(alpha: 0.65)),
                boxShadow: FarmPalette.shadow(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _FarmStatusLight(color: status.$2, active: active > 0),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(status.$1, style: TextStyle(color: status.$2, fontSize: 10, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('${printer.printer.model} · ${printer.printer.channelCount} 槽', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 9)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return node;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: node),
    );
  }
}

class _FarmFloorPainter extends CustomPainter {
  const _FarmFloorPainter({
    required this.lineColor,
    required this.laneColor,
    required this.accent,
    required this.backgroundColor,
  });
  final Color lineColor;
  final Color laneColor;
  final Color accent;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = backgroundColor;
    canvas.drawRect(Offset.zero & size, background);
    final grid = Paint()..color = lineColor..strokeWidth = 1;
    const step = 32.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), grid);
      canvas.drawLine(Offset(x, 0), Offset(x - size.height, size.height), grid);
    }
    final lane = Paint()..color = laneColor;
    for (var row = 0; row < 5; row++) {
      final y = 76.0 + row * 168;
      canvas.drawRect(Rect.fromLTWH(20, y, size.width - 40, 128), lane);
      final divider = Paint()..color = accent.withValues(alpha: 0.16)..strokeWidth = 1;
      canvas.drawLine(
        Offset(24, y + 128),
        Offset(size.width - 24, y + 128),
        divider,
      );
    }
    final route = Paint()..color = accent.withValues(alpha: 0.28)..strokeWidth = 2;
    for (var x = 80.0; x < size.width; x += 222) {
      canvas.drawLine(Offset(x, 52), Offset(x, size.height - 32), route);
    }
  }

  @override
  bool shouldRepaint(covariant _FarmFloorPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor ||
      oldDelegate.laneColor != laneColor ||
      oldDelegate.backgroundColor != backgroundColor;
}

class _FarmIsometricPrinterPainter extends CustomPainter {
  const _FarmIsometricPrinterPainter({required this.accent, required this.running});
  final Color accent;
  final bool running;

  @override
  void paint(Canvas canvas, Size size) {
    final shadow = Paint()..color = Colors.black.withValues(alpha: 0.42);
    canvas.drawOval(Rect.fromLTWH(7, 80, 116, 18), shadow);
    final shell = Paint()..color = const Color(0xFF28372F);
    final side = Paint()..color = const Color(0xFF1A251F);
    final rim = Paint()..color = accent.withValues(alpha: 0.78)..style = PaintingStyle.stroke..strokeWidth = 1.4;
    final machine = Path()
      ..moveTo(20, 28)
      ..lineTo(94, 16)
      ..lineTo(121, 30)
      ..lineTo(44, 43)
      ..close();
    canvas.drawPath(machine, shell);
    canvas.drawPath(machine, rim);
    final body = Path()
      ..moveTo(20, 28)
      ..lineTo(20, 76)
      ..lineTo(44, 92)
      ..lineTo(44, 43)
      ..close();
    canvas.drawPath(body, side);
    canvas.drawPath(body, rim);
    final front = Path()
      ..moveTo(44, 43)
      ..lineTo(121, 30)
      ..lineTo(121, 76)
      ..lineTo(44, 92)
      ..close();
    canvas.drawPath(front, shell);
    canvas.drawPath(front, rim);
    final window = Paint()..color = accent.withValues(alpha: running ? 0.28 : 0.08);
    canvas.drawPath(Path()
      ..moveTo(55, 49)
      ..lineTo(110, 40)
      ..lineTo(110, 68)
      ..lineTo(55, 79)
      ..close(), window);
    if (running) {
      final beam = Paint()..color = accent.withValues(alpha: 0.82)..strokeWidth = 2;
      canvas.drawLine(const Offset(82, 52), const Offset(82, 73), beam);
      canvas.drawLine(const Offset(72, 73), const Offset(92, 73), beam);
    }
    canvas.drawCircle(const Offset(110, 34), 3, Paint()..color = accent);
    final spool = Paint()..color = accent.withValues(alpha: 0.75);
    canvas.drawOval(Rect.fromLTWH(97, 74, 17, 7), spool);
  }

  @override
  bool shouldRepaint(covariant _FarmIsometricPrinterPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.running != running;
}

class _FarmStatusLight extends StatelessWidget {
  const _FarmStatusLight({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: active
              ? [BoxShadow(color: color.withValues(alpha: 0.65), blurRadius: 8)]
              : null,
        ),
      );
}

class _FarmChannelBar extends StatelessWidget {
  const _FarmChannelBar({required this.channel, required this.accent});
  final ChannelWithConsumable? channel;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final color = channel?.consumable == null
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : parseHexColor(channel!.consumable!.colorHex);
    final active = channel?.isActive ?? false;
    return Tooltip(
      message: channel?.consumable?.colorName ?? '未配置通道',
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          color: color.withValues(alpha: active ? 0.95 : 0.35),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? color : accent.withValues(alpha: 0.2)),
        ),
      ),
    );
  }
}

class _FarmPrinterPainter extends CustomPainter {
  const _FarmPrinterPainter({required this.accent, required this.running});
  final Color accent;
  final bool running;

  @override
  void paint(Canvas canvas, Size size) {
    final shell = Paint()
      ..color = const Color(0xFF3B4942)
      ..style = PaintingStyle.fill;
    final edge = Paint()
      ..color = accent.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final inner = Paint()
      ..color = accent.withValues(alpha: running ? 0.22 : 0.08)
      ..style = PaintingStyle.fill;
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(18, 15, size.width - 30, size.height - 27),
      const Radius.circular(8),
    );
    canvas.drawRRect(box, shell);
    canvas.drawRRect(box, edge);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(28, 29, size.width - 50, size.height - 50),
        const Radius.circular(4),
      ),
      inner,
    );
    canvas.drawLine(const Offset(28, 29), Offset(size.width - 22, 29), edge);
    final dot = Paint()..color = accent;
    canvas.drawCircle(const Offset(29, 22), 3, dot);
    canvas.drawLine(
      Offset(36, size.height - 13),
      Offset(size.width - 24, size.height - 13),
      edge,
    );
    if (running) {
      final beam = Paint()
        ..color = accent.withValues(alpha: 0.8)
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(size.width / 2, 37),
        Offset(size.width / 2, size.height - 22),
        beam,
      );
      canvas.drawLine(
        Offset(size.width / 2 - 8, size.height - 22),
        Offset(size.width / 2 + 8, size.height - 22),
        beam,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FarmPrinterPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.running != running;
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

String formatGrams(double grams) {
  if (grams >= 1000) return '${(grams / 1000).toStringAsFixed(2)} kg';
  return '${grams.toStringAsFixed(0)} g';
}

String formatDate(DateTime? value) {
  if (value == null) return '-';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

Color parseHexColor(String hex) {
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length != 6) return FarmPalette.primary;
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return FarmPalette.primary;
  return Color(0xFF000000 | value);
}
