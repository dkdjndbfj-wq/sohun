import 'dart:async';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/gram_utils.dart';
import '../../providers/filament_cost_provider.dart';
import '../../widgets/app_input.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';

/// 当前选中的汇总时间范围（页面内 StateProvider）
final _summaryRangeProvider = StateProvider<ConsumptionRange>(
  (ref) => ConsumptionRange.today,
);

enum _CostSaveStatus { loading, saving, saved }

/// 耗材成本管理页。
///
/// 顶部：成本参数设置（电费单价、打印机功率、待机功率、机器损耗率、每小时人工费），
/// 这些参数用于主界面打印任务的成本计算。
///
/// 中部：耗材消耗统计卡片（总消耗克数、总成本、今日消耗、本月消耗等）。
///
/// 底部：消耗趋势折线图（今日每半小时 / 本周7天 / 本月1号起）。
///
/// v4 视觉升级：TextField → AppInput（聚焦光环 + 自动暗色），
/// 全量暗色模式适配（统计块、折线图文字、范围切换）。
/// 保留 inline 结构与所有 provider 调用。
class FilamentCostScreen extends ConsumerStatefulWidget {
  const FilamentCostScreen({super.key});

  @override
  ConsumerState<FilamentCostScreen> createState() => _FilamentCostScreenState();
}

class _FilamentCostScreenState extends ConsumerState<FilamentCostScreen> {
  // 成本参数控制器（持久化到 SharedPreferences）
  final _elecPriceController = TextEditingController(text: '0.6');
  final _printerPowerController = TextEditingController(text: '150');
  final _idlePowerController = TextEditingController(text: '30');
  final _wearRateController = TextEditingController(text: '0.5');
  final _laborRateController = TextEditingController(text: '0');
  Timer? _saveDebounce;
  _CostSaveStatus _saveStatus = _CostSaveStatus.loading;
  int _saveRevision = 0;

  // 成本参数持久化键
  static const _kElecPrice = 'cost_elec_price'; // 电费单价（元/度）
  static const _kPrinterPower = 'cost_printer_power'; // 打印机功率（W）
  static const _kIdlePower = 'cost_idle_power'; // 待机/预热功率（W）
  static const _kWearRate = 'cost_wear_rate'; // 机器损耗率（元/小时）
  static const _kLaborRate = 'cost_labor_rate'; // 每小时人工费（元/小时）

  @override
  void initState() {
    super.initState();
    _loadCostSettings();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _elecPriceController.dispose();
    _printerPowerController.dispose();
    _idlePowerController.dispose();
    _wearRateController.dispose();
    _laborRateController.dispose();
    super.dispose();
  }

  Future<void> _loadCostSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _elecPriceController.text = (prefs.getDouble(_kElecPrice) ?? 0.6)
            .toString();
        _printerPowerController.text = (prefs.getDouble(_kPrinterPower) ?? 150)
            .toString();
        _idlePowerController.text = (prefs.getDouble(_kIdlePower) ?? 30)
            .toString();
        _wearRateController.text = (prefs.getDouble(_kWearRate) ?? 0.5)
            .toString();
        _laborRateController.text = (prefs.getDouble(_kLaborRate) ?? 0)
            .toString();
        _saveStatus = _CostSaveStatus.saved;
      });
    }
  }

  void _queueCostSettingsSave() {
    _saveDebounce?.cancel();
    final revision = ++_saveRevision;
    setState(() => _saveStatus = _CostSaveStatus.saving);
    _saveDebounce = Timer(
      const Duration(milliseconds: 420),
      () => unawaited(_saveCostSettings(revision)),
    );
  }

  Future<void> _saveCostSettings(int revision) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _kElecPrice,
      double.tryParse(_elecPriceController.text) ?? 0.6,
    );
    await prefs.setDouble(
      _kPrinterPower,
      double.tryParse(_printerPowerController.text) ?? 150,
    );
    await prefs.setDouble(
      _kIdlePower,
      double.tryParse(_idlePowerController.text) ?? 30,
    );
    await prefs.setDouble(
      _kWearRate,
      double.tryParse(_wearRateController.text) ?? 0.5,
    );
    await prefs.setDouble(
      _kLaborRate,
      double.tryParse(_laborRateController.text) ?? 0,
    );
    if (mounted && revision == _saveRevision) {
      setState(() => _saveStatus = _CostSaveStatus.saved);
    }
  }

  double _valueOf(TextEditingController controller, double fallback) {
    return double.tryParse(controller.text) ?? fallback;
  }

  @override
  Widget build(BuildContext context) {
    final costConfigs =
        ref.watch(filamentCostConfigsProvider).valueOrNull ?? const [];
    final configuredPrices = costConfigs
        .map((config) => config.costPerKg)
        .where((price) => price > 0)
        .toList(growable: false);
    final averageFilamentPrice = configuredPrices.isEmpty
        ? null
        : configuredPrices.reduce((a, b) => a + b) / configuredPrices.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          // 1. 成本参数设置卡片
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final settings = _CostSettingsCard(
                    elecPriceController: _elecPriceController,
                    printerPowerController: _printerPowerController,
                    idlePowerController: _idlePowerController,
                    wearRateController: _wearRateController,
                    laborRateController: _laborRateController,
                    saveStatus: _saveStatus,
                    onChanged: _queueCostSettingsSave,
                  );
                  final simulator = _CostScenarioLab(
                    suggestedFilamentPrice: averageFilamentPrice,
                    electricityPrice: _valueOf(_elecPriceController, 0.6),
                    printerPower: _valueOf(_printerPowerController, 150),
                    wearRate: _valueOf(_wearRateController, 0.5),
                    laborRate: _valueOf(_laborRateController, 0),
                  );
                  if (constraints.maxWidth < 920) {
                    return Column(
                      children: [
                        settings,
                        const SizedBox(height: 12),
                        simulator,
                      ],
                    );
                  }
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 11, child: settings),
                        const SizedBox(width: 12),
                        Expanded(flex: 9, child: simulator),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          // 2. 耗材消耗统计卡片（今日/本月/累计）
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: _ConsumptionStatsCard(),
            ),
          ),
          // 3. 消耗趋势折线图
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: _ConsumptionChartCard(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 成本参数设置卡片。仅设置电费/功率/待机功率/损耗率/人工费，打印克数和时长从任务读取。
class _CostSettingsCard extends StatelessWidget {
  final TextEditingController elecPriceController;
  final TextEditingController printerPowerController;
  final TextEditingController idlePowerController;
  final TextEditingController wearRateController;
  final TextEditingController laborRateController;
  final _CostSaveStatus saveStatus;
  final VoidCallback onChanged;

  const _CostSettingsCard({
    required this.elecPriceController,
    required this.printerPowerController,
    required this.idlePowerController,
    required this.wearRateController,
    required this.laborRateController,
    required this.saveStatus,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_outlined, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                '成本参数设置',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              _SaveStatusBadge(status: saveStatus),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '这些参数用于主界面打印任务的成本计算',
            style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          // 2 列网格：电费单价 + 打印机功率
          Row(
            children: [
              Expanded(
                child: _ParamInput(
                  label: '电费单价',
                  controller: elecPriceController,
                  suffix: '元/度',
                  icon: Icons.bolt_outlined,
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ParamInput(
                  label: '打印机功率',
                  controller: printerPowerController,
                  suffix: 'W',
                  icon: Icons.electrical_services_outlined,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 2 列网格：待机功率 + 机器损耗率
          Row(
            children: [
              Expanded(
                child: _ParamInput(
                  label: '待机功率',
                  controller: idlePowerController,
                  suffix: 'W',
                  icon: Icons.power_settings_new_outlined,
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ParamInput(
                  label: '机器损耗率',
                  controller: wearRateController,
                  suffix: '元/小时',
                  icon: Icons.precision_manufacturing_outlined,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 单列：每小时人工费
          Row(
            children: [
              Expanded(
                child: _ParamInput(
                  label: '每小时人工费',
                  controller: laborRateController,
                  suffix: '元/小时',
                  icon: Icons.person_outlined,
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 10),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

class _SaveStatusBadge extends StatelessWidget {
  const _SaveStatusBadge({
    required this.status,
    this.badgeKey = const ValueKey('cost-save-status'),
    this.savingLabel = '保存中',
    this.savedLabel = '已保存',
    this.loadingLabel = '读取中',
  });

  final _CostSaveStatus status;
  final Key badgeKey;
  final String savingLabel;
  final String savedLabel;
  final String loadingLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saving = status == _CostSaveStatus.saving;
    final loaded = status != _CostSaveStatus.loading;
    return AnimatedContainer(
      key: badgeKey,
      duration: AppMotion.duration(context, const Duration(milliseconds: 180)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: saving
            ? scheme.primary.withValues(alpha: 0.08)
            : AppColors.success.withValues(alpha: loaded ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedSwitcher(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 160),
        ),
        child: Row(
          key: ValueKey(status),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (saving)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: scheme.primary,
                ),
              )
            else
              Icon(
                loaded ? Icons.check_rounded : Icons.sync_rounded,
                size: 13,
                color: loaded ? AppColors.success : scheme.onSurfaceVariant,
              ),
            const SizedBox(width: 5),
            Text(
              saving
                  ? savingLabel
                  : loaded
                  ? savedLabel
                  : loadingLabel,
              style: TextStyle(
                color: saving
                    ? scheme.primary
                    : loaded
                    ? AppColors.success
                    : scheme.onSurfaceVariant,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 参数输入框。v4：内部 TextField 改用 AppInput（聚焦光环 + 自动暗色）。
/// 单位合并到 label 末尾展示，icon 作为 prefixIcon 保留语义。
class _ParamInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String suffix;
  final IconData icon;
  final ValueChanged<String> onChanged;

  const _ParamInput({
    required this.label,
    required this.controller,
    required this.suffix,
    required this.icon,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppInput(
      label: '$label · $suffix',
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: onChanged,
      prefixIcon: Icon(icon, size: 14),
    );
  }
}

class _CostScenarioLab extends StatefulWidget {
  const _CostScenarioLab({
    required this.suggestedFilamentPrice,
    required this.electricityPrice,
    required this.printerPower,
    required this.wearRate,
    required this.laborRate,
  });

  /// 仅用于用户主动“带入”，报价不会自动跟随耗材成本配置变化。
  final double? suggestedFilamentPrice;
  final double electricityPrice;
  final double printerPower;
  final double wearRate;
  final double laborRate;

  @override
  State<_CostScenarioLab> createState() => _CostScenarioLabState();
}

class _CostScenarioLabState extends State<_CostScenarioLab> {
  static const _kQuoteFilamentPrice = 'cost_quote_filament_price_per_kg';
  static const _presets = <(String, double, double)>[
    ('小件', 80, 2),
    ('常规', 250, 6),
    ('长任务', 600, 16),
  ];

  final _filamentPriceController = TextEditingController();
  Timer? _filamentPriceSaveDebounce;
  _CostSaveStatus _filamentPriceSaveStatus = _CostSaveStatus.loading;
  int _filamentPriceSaveRevision = 0;
  double _grams = 250;
  double _hours = 6;
  int _selectedPreset = 1;

  @override
  void initState() {
    super.initState();
    _loadQuoteFilamentPrice();
  }

  @override
  void dispose() {
    _filamentPriceSaveDebounce?.cancel();
    _filamentPriceController.dispose();
    super.dispose();
  }

  Future<void> _loadQuoteFilamentPrice() async {
    final prefs = await SharedPreferences.getInstance();
    final price = prefs.getDouble(_kQuoteFilamentPrice);
    if (!mounted) return;
    setState(() {
      _filamentPriceController.text = price == null ? '' : _formatPrice(price);
      _filamentPriceSaveStatus = _CostSaveStatus.saved;
    });
  }

  void _onFilamentPriceChanged(String _) {
    _filamentPriceSaveDebounce?.cancel();
    final revision = ++_filamentPriceSaveRevision;
    setState(() => _filamentPriceSaveStatus = _CostSaveStatus.saving);
    _filamentPriceSaveDebounce = Timer(
      const Duration(milliseconds: 420),
      () => unawaited(_saveQuoteFilamentPrice(revision)),
    );
  }

  Future<void> _saveQuoteFilamentPrice(int revision) async {
    final prefs = await SharedPreferences.getInstance();
    final price = _filamentPrice;
    if (price == null) {
      await prefs.remove(_kQuoteFilamentPrice);
    } else {
      await prefs.setDouble(_kQuoteFilamentPrice, price);
    }
    if (mounted && revision == _filamentPriceSaveRevision) {
      setState(() => _filamentPriceSaveStatus = _CostSaveStatus.saved);
    }
  }

  void _useSuggestedFilamentPrice() {
    final price = widget.suggestedFilamentPrice;
    if (price == null || price <= 0) return;
    _filamentPriceController.text = _formatPrice(price);
    _onFilamentPriceChanged(_filamentPriceController.text);
  }

  double? get _filamentPrice {
    final price = double.tryParse(_filamentPriceController.text.trim());
    return price != null && price > 0 ? price : null;
  }

  String _formatPrice(double price) =>
      price.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  void _applyPreset(int index) {
    final preset = _presets[index];
    setState(() {
      _selectedPreset = index;
      _grams = preset.$2;
      _hours = preset.$3;
    });
  }

  void _setGrams(double value) {
    setState(() {
      _selectedPreset = -1;
      _grams = value;
    });
  }

  void _setHours(double value) {
    setState(() {
      _selectedPreset = -1;
      _hours = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filamentPrice = _filamentPrice;
    final filamentCost = _grams / 1000 * (filamentPrice ?? 0);
    final electricityCost =
        _hours * (widget.printerPower / 1000) * widget.electricityPrice;
    final wearCost = _hours * widget.wearRate;
    final laborCost = _hours * widget.laborRate;
    final parts = <_CostPart>[
      _CostPart('耗材', filamentCost, scheme.primary),
      const _CostPart(
        '电费',
        0,
        AppColors.warning,
      ).copyWith(value: electricityCost),
      const _CostPart('损耗', 0, AppColors.info).copyWith(value: wearCost),
      const _CostPart('人工', 0, AppColors.success).copyWith(value: laborCost),
    ];
    final total = parts.fold<double>(0, (sum, part) => sum + part.value);

    return GlassCard(
      key: const ValueKey('cost-scenario-lab'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.tune_rounded,
                  size: 17,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '即时报价试算',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '拖动参数，立即查看成本构成',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              _SaveStatusBadge(
                status: _filamentPriceSaveStatus,
                badgeKey: const ValueKey('quote-cost-save-status'),
                savingLabel: '报价保存中',
                savedLabel: '报价已保存',
                loadingLabel: '读取报价',
              ),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: AppInput(
                  key: const ValueKey('quote-filament-price-input'),
                  label: '报价耗材成本 · 元/kg',
                  hint: '单独设置本模块使用的成本',
                  controller: _filamentPriceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  prefixIcon: const Icon(Icons.inventory_2_outlined, size: 14),
                  onChanged: _onFilamentPriceChanged,
                ),
              ),
              if (widget.suggestedFilamentPrice case final price?) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: '只复制当前耗材成本均价一次，之后不自动联动',
                  child: SizedBox(
                    height: 40,
                    child: OutlinedButton.icon(
                      key: const ValueKey('quote-use-average-price'),
                      onPressed: _useSuggestedFilamentPrice,
                      icon: const Icon(Icons.input_rounded, size: 15),
                      label: Text('带入均价 ¥${_formatPrice(price)}/kg'),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '独立保存为报价默认值；库存耗材单价和历史成本不会自动改动它。',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 9),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (var index = 0; index < _presets.length; index++)
                _ScenarioPresetButton(
                  key: ValueKey('cost-preset-$index'),
                  label: _presets[index].$1,
                  detail:
                      '${_presets[index].$2.toStringAsFixed(0)}g · ${_presets[index].$3.toStringAsFixed(0)}h',
                  selected: _selectedPreset == index,
                  onTap: () => _applyPreset(index),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ScenarioSlider(
            key: const ValueKey('cost-grams-slider'),
            label: '预计用料',
            valueLabel: '${_grams.toStringAsFixed(0)} g',
            value: _grams,
            min: 20,
            max: 1000,
            divisions: 98,
            onChanged: _setGrams,
          ),
          const SizedBox(height: 5),
          _ScenarioSlider(
            key: const ValueKey('cost-hours-slider'),
            label: '打印时长',
            valueLabel: '${_hours.toStringAsFixed(1)} 小时',
            value: _hours,
            min: 0.5,
            max: 24,
            divisions: 47,
            onChanged: _setHours,
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '预计成本',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: total),
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 240),
                      ),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => Text(
                        '¥${value.toStringAsFixed(2)}',
                        key: const ValueKey('cost-scenario-total'),
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 27,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                filamentPrice == null
                    ? '未设置报价耗材成本'
                    : '报价成本 ¥${_formatPrice(filamentPrice)}/kg',
                style: TextStyle(
                  color: filamentPrice == null
                      ? AppColors.warning
                      : scheme.onSurfaceVariant,
                  fontSize: 9,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _CostBreakdownBar(parts: parts, total: total),
          const SizedBox(height: 8),
          Wrap(
            spacing: 11,
            runSpacing: 5,
            children: [for (final part in parts) _CostLegendItem(part: part)],
          ),
          const SizedBox(height: 8),
          Text(
            filamentPrice == null
                ? '请先设置本报价使用的耗材成本；系统不会擅自使用库存均价。'
                : '耗材费按本模块独立设置的 ¥${_formatPrice(filamentPrice)}/kg 计算。',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 9),
          ),
        ],
      ),
    );
  }
}

class _ScenarioSlider extends StatelessWidget {
  const _ScenarioSlider({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              valueLabel,
              style: TextStyle(
                color: scheme.primary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _ScenarioPresetButton extends StatefulWidget {
  const _ScenarioPresetButton({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ScenarioPresetButton> createState() => _ScenarioPresetButtonState();
}

class _ScenarioPresetButtonState extends State<_ScenarioPresetButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (GlassButtonsTheme.enabledOf(context)) {
      return Semantics(
        selected: widget.selected,
        child: AppGlassButton(
          label: '${widget.label} ${widget.detail}',
          onPressed: widget.onTap,
          variant: widget.selected
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.quiet,
          compact: true,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          borderRadius: BorderRadius.circular(10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                widget.detail,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 9),
              ),
            ],
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering && AppMotion.enabled(context) ? 1.025 : 1,
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 130),
        ),
        child: Material(
          color: widget.selected
              ? scheme.primary.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(9),
            child: AnimatedContainer(
              duration: AppMotion.duration(
                context,
                const Duration(milliseconds: 160),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: widget.selected
                      ? scheme.primary.withValues(alpha: 0.42)
                      : scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.selected
                          ? scheme.primary
                          : scheme.onSurface,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    widget.detail,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CostPart {
  const _CostPart(this.label, this.value, this.color);

  final String label;
  final double value;
  final Color color;

  _CostPart copyWith({double? value}) =>
      _CostPart(label, value ?? this.value, color);
}

class _CostBreakdownBar extends StatelessWidget {
  const _CostBreakdownBar({required this.parts, required this.total});

  final List<_CostPart> parts;
  final double total;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('cost-breakdown-bar'),
      height: 8,
      child: LayoutBuilder(
        builder: (context, constraints) {
          var offset = 0.0;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(99),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Stack(
                children: [
                  for (final part in parts)
                    Builder(
                      builder: (context) {
                        final fraction = total <= 0 ? 0.0 : part.value / total;
                        final left = offset;
                        offset += fraction;
                        return AnimatedPositioned(
                          key: ValueKey('cost-segment-${part.label}'),
                          left: constraints.maxWidth * left,
                          width: constraints.maxWidth * fraction,
                          top: 0,
                          bottom: 0,
                          duration: AppMotion.duration(
                            context,
                            const Duration(milliseconds: 240),
                          ),
                          curve: Curves.easeOutCubic,
                          child: Tooltip(
                            message:
                                '${part.label} ¥${part.value.toStringAsFixed(2)}',
                            child: ColoredBox(color: part.color),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CostLegendItem extends StatelessWidget {
  const _CostLegendItem({required this.part});

  final _CostPart part;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: part.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '${part.label} ¥${part.value.toStringAsFixed(2)}',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 9,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 耗材消耗统计卡片。展示今日/本月/累计的消耗克数和成本。
class _ConsumptionStatsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final todayAsync = ref.watch(
      consumptionSummaryProvider(ConsumptionRange.today),
    );
    final monthAsync = ref.watch(
      consumptionSummaryProvider(ConsumptionRange.month),
    );
    final range = ref.watch(_summaryRangeProvider);
    void showRange(ConsumptionRange next) {
      ref.read(_summaryRangeProvider.notifier).state = next;
    }

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                '耗材消耗统计',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 4 个统计块：今日消耗/今日成本/本月消耗/本月成本
          Row(
            children: [
              Expanded(
                child: todayAsync.when(
                  loading: () => const _StatBox.loading(),
                  error: (_, __) => const _StatBox.error(),
                  data: (s) => _StatBox(
                    key: const ValueKey('cost-stat-today-grams'),
                    label: '今日消耗',
                    value: GramUtils.formatGrams(s.totalGrams),
                    unit: 'g',
                    icon: Icons.today_outlined,
                    color: AppColors.warning,
                    selected: range == ConsumptionRange.today,
                    onTap: () => showRange(ConsumptionRange.today),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: todayAsync.when(
                  loading: () => const _StatBox.loading(),
                  error: (_, __) => const _StatBox.error(),
                  data: (s) => _StatBox(
                    key: const ValueKey('cost-stat-today-value'),
                    label: '今日成本',
                    value: s.totalCost.toStringAsFixed(1),
                    unit: '元',
                    icon: Icons.payments_outlined,
                    color: AppColors.primary,
                    highlight: true,
                    selected: range == ConsumptionRange.today,
                    onTap: () => showRange(ConsumptionRange.today),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: monthAsync.when(
                  loading: () => const _StatBox.loading(),
                  error: (_, __) => const _StatBox.error(),
                  data: (s) => _StatBox(
                    key: const ValueKey('cost-stat-month-grams'),
                    label: '本月消耗',
                    value: GramUtils.formatGrams(s.totalGrams),
                    unit: 'g',
                    icon: Icons.calendar_month_outlined,
                    color: AppColors.info,
                    selected: range == ConsumptionRange.month,
                    onTap: () => showRange(ConsumptionRange.month),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: monthAsync.when(
                  loading: () => const _StatBox.loading(),
                  error: (_, __) => const _StatBox.error(),
                  data: (s) => _StatBox(
                    key: const ValueKey('cost-stat-month-value'),
                    label: '本月成本',
                    value: s.totalCost.toStringAsFixed(1),
                    unit: '元',
                    icon: Icons.account_balance_wallet_outlined,
                    color: AppColors.success,
                    selected: range == ConsumptionRange.month,
                    onTap: () => showRange(ConsumptionRange.month),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 统计数字块
class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;
  final bool highlight;
  final bool selected;
  final VoidCallback? onTap;

  const _StatBox({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    this.highlight = false,
    this.selected = false,
    this.onTap,
  });

  const _StatBox.loading()
    : label = '加载中',
      value = '—',
      unit = '',
      icon = Icons.hourglass_top_rounded,
      color = AppColors.textTertiary,
      highlight = false,
      selected = false,
      onTap = null;

  const _StatBox.error()
    : label = '出错',
      value = '—',
      unit = '',
      icon = Icons.error_outline_rounded,
      color = AppColors.danger,
      highlight = false,
      selected = false,
      onTap = null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = AnimatedContainer(
      duration: AppMotion.duration(context, const Duration(milliseconds: 170)),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight
            ? color.withValues(alpha: 0.08)
            : (isDark
                  ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                  : AppColors.surfaceVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(
          color: selected
              ? color.withValues(alpha: 0.48)
              : highlight
              ? color.withValues(alpha: 0.20)
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: highlight
                            ? color
                            : (isDark
                                  ? AppColors.textPrimaryDark
                                  : AppColors.textPrimary),
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      unit,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(
              Icons.arrow_forward_rounded,
              size: 13,
              color: selected ? color : color.withValues(alpha: 0.55),
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return Tooltip(
      message: label.startsWith('今日') ? '查看今日趋势' : '查看本月趋势',
      child: TactileLift(
        maxTilt: 0.008,
        lift: 1.5,
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// 消耗趋势折线图卡片。
///
/// 横坐标：
/// - 今日：每半小时一个点（0:00 到当前时间，最多 48 个点）
/// - 本周：7 天内每天一个点
/// - 本月：从 1 号到今天每天一个点
class _ConsumptionChartCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final range = ref.watch(_summaryRangeProvider);
    final async = ref.watch(consumptionTimelineProvider(range));

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.show_chart_rounded,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '消耗趋势',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              _RangeToggle(
                range: range,
                onChanged: (r) =>
                    ref.read(_summaryRangeProvider.notifier).state = r,
              ),
            ],
          ),
          const SizedBox(height: 14),
          async.when(
            loading: () => const SizedBox(
              height: 180,
              child: LoadingState(label: '加载成本数据…'),
            ),
            error: (e, _) => SizedBox(
              height: 180,
              child: Center(
                child: Text(
                  '加载失败: ${friendlyError(e)}',
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            ),
            data: (points) {
              if (points.isEmpty) {
                return _buildEmpty(range, isDark);
              }
              return _ConsumptionChart(
                points: points,
                range: range,
                isDark: isDark,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ConsumptionRange range, bool isDark) {
    final label = switch (range) {
      ConsumptionRange.today => '今日',
      ConsumptionRange.week => '本周',
      ConsumptionRange.month => '本月',
    };
    return SizedBox(
      height: 180,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 32,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
            const SizedBox(height: 8),
            Text(
              '$label还没有完成的打印任务',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 折线图组件。用 CustomPaint 自绘，无需第三方库。
class _ConsumptionChart extends StatefulWidget {
  final List<ConsumptionPoint> points;
  final ConsumptionRange range;
  final bool isDark;

  const _ConsumptionChart({
    required this.points,
    required this.range,
    required this.isDark,
  });

  @override
  State<_ConsumptionChart> createState() => _ConsumptionChartState();
}

class _ConsumptionChartState extends State<_ConsumptionChart> {
  int? _activeIndex;

  void _inspect(Offset position, Size size) {
    if (widget.points.isEmpty) return;
    const chartLeft = 36.0;
    final chartWidth = size.width - chartLeft - 8;
    if (chartWidth <= 0) return;
    final normalized = ((position.dx - chartLeft) / chartWidth).clamp(0.0, 1.0);
    final index = (normalized * (widget.points.length - 1)).round();
    if (index != _activeIndex) setState(() => _activeIndex = index);
  }

  String _timeLabel(ConsumptionPoint point) {
    if (widget.range == ConsumptionRange.today) {
      final hour = point.time.hour.toString().padLeft(2, '0');
      final minute = point.time.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    return '${point.time.month}/${point.time.day}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 200);
        final active = _activeIndex == null
            ? null
            : widget.points[_activeIndex!.clamp(0, widget.points.length - 1)];
        const chartLeft = 36.0;
        final chartWidth = constraints.maxWidth - chartLeft - 8;
        final pointX = active == null
            ? 0.0
            : widget.points.length == 1
            ? chartLeft + chartWidth / 2
            : chartLeft +
                  chartWidth * _activeIndex! / (widget.points.length - 1);
        const tooltipWidth = 128.0;
        final tooltipLeft = (pointX - tooltipWidth / 2).clamp(
          0.0,
          constraints.maxWidth - tooltipWidth,
        );
        return MouseRegion(
          key: const ValueKey('cost-consumption-chart'),
          cursor: SystemMouseCursors.precise,
          onHover: (event) => _inspect(event.localPosition, size),
          onExit: (_) => setState(() => _activeIndex = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _inspect(details.localPosition, size),
            onHorizontalDragUpdate: (details) =>
                _inspect(details.localPosition, size),
            child: SizedBox(
              height: 200,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _LineChartPainter(
                        points: widget.points,
                        range: widget.range,
                        isDark: widget.isDark,
                        activeIndex: _activeIndex,
                      ),
                    ),
                  ),
                  if (active != null)
                    Positioned(
                      key: const ValueKey('cost-chart-tooltip'),
                      left: tooltipLeft,
                      top: 2,
                      width: tooltipWidth,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surface.withValues(alpha: 0.96),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 12,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            child: Text(
                              '${_timeLabel(active)}  ${GramUtils.formatGrams(active.grams)}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  ui.FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 折线图画笔。
///
/// 绘制内容：
/// - Y 轴网格线（3 条水平虚线）
/// - X 轴标签（时间）
/// - 折线 + 填充渐变
/// - 数据点圆点
///
/// v4：传入 isDark，网格线 / 文字 / 数据点边色按模式切换，确保暗色下可读。
class _LineChartPainter extends CustomPainter {
  final List<ConsumptionPoint> points;
  final ConsumptionRange range;
  final bool isDark;
  final int? activeIndex;

  _LineChartPainter({
    required this.points,
    required this.range,
    required this.isDark,
    required this.activeIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const chartLeft = 36.0;
    final chartRight = size.width - 8;
    const chartTop = 12.0;
    final chartBottom = size.height - 28;
    final chartW = chartRight - chartLeft;
    final chartH = chartBottom - chartTop;

    // 找最大值
    final maxVal = points.fold<double>(
      0,
      (max, p) => p.grams > max ? p.grams : max,
    );
    final yMax = maxVal <= 0 ? 1.0 : maxVal * 1.15;

    // 暗色模式下的图表配色
    final gridColor = (isDark ? AppColors.outlineDark : AppColors.outline)
        .withValues(alpha: 0.3);
    final axisLabelColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    // 绘制 Y 轴网格线 + 标签
    final gridPaint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final labelStyle = TextStyle(fontSize: 9, color: axisLabelColor);
    for (int i = 0; i <= 3; i++) {
      final y = chartTop + chartH * i / 3;
      // 虚线
      final dashPath = Path();
      double dashW = 3, dashSpace = 3;
      double startX = chartLeft;
      while (startX < chartRight) {
        dashPath.moveTo(startX, y);
        dashPath.lineTo((startX + dashW).clamp(chartLeft, chartRight), y);
        startX += dashW + dashSpace;
      }
      canvas.drawPath(dashPath, gridPaint);

      // Y 轴标签
      final val = yMax * (1 - i / 3);
      final label = val >= 1000
          ? '${(val / 1000).toStringAsFixed(1)}k'
          : val.toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(text: '${label}g', style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(chartLeft - tp.width - 4, y - tp.height / 2));
    }

    // 计算每个点的坐标
    final pointCount = points.length;
    List<Offset> coords = [];
    for (int i = 0; i < pointCount; i++) {
      final x = pointCount == 1
          ? chartLeft + chartW / 2
          : chartLeft + chartW * i / (pointCount - 1);
      final y = chartTop + chartH * (1 - points[i].grams / yMax);
      coords.add(Offset(x, y));
    }

    // 绘制填充渐变
    if (coords.length >= 2) {
      final fillPath = Path()
        ..moveTo(coords.first.dx, chartBottom)
        ..lineTo(coords.first.dx, coords.first.dy);
      for (int i = 1; i < coords.length; i++) {
        // 用平滑曲线连接
        final midX = (coords[i - 1].dx + coords[i].dx) / 2;
        fillPath.cubicTo(
          midX,
          coords[i - 1].dy,
          midX,
          coords[i].dy,
          coords[i].dx,
          coords[i].dy,
        );
      }
      fillPath.lineTo(coords.last.dx, chartBottom);
      fillPath.close();

      final fillPaint = Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, chartTop),
          Offset(0, chartBottom),
          [
            AppColors.primary.withValues(alpha: 0.25),
            AppColors.primary.withValues(alpha: 0.0),
          ],
        )
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);

      // 绘制折线
      final linePath = Path()..moveTo(coords.first.dx, coords.first.dy);
      for (int i = 1; i < coords.length; i++) {
        final midX = (coords[i - 1].dx + coords[i].dx) / 2;
        linePath.cubicTo(
          midX,
          coords[i - 1].dy,
          midX,
          coords[i].dy,
          coords[i].dx,
          coords[i].dy,
        );
      }
      final linePaint = Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(linePath, linePaint);
    }

    // 绘制数据点
    final dotPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.fill;
    // v4：数据点外圈描边色按模式切换（亮色白高光 / 暗色深色融合）
    final dotBorderPaint = Paint()
      ..color = isDark ? AppColors.surfaceDark : Colors.white
      ..style = PaintingStyle.fill;
    for (final c in coords) {
      canvas.drawCircle(c, 3.5, dotBorderPaint);
      canvas.drawCircle(c, 2.5, dotPaint);
    }
    if (activeIndex != null && activeIndex! < coords.length) {
      final active = coords[activeIndex!];
      canvas.drawLine(
        Offset(active.dx, chartTop),
        Offset(active.dx, chartBottom),
        Paint()
          ..color = AppColors.primary.withValues(alpha: 0.24)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        active,
        8,
        Paint()..color = AppColors.primary.withValues(alpha: 0.16),
      );
      canvas.drawCircle(active, 4.5, dotBorderPaint);
      canvas.drawCircle(active, 3.2, dotPaint);
    }

    // 绘制 X 轴标签：均匀分布，确保首尾（0:00/当前时间）都显示
    const maxLabels = 6;
    final xLabelStyle = TextStyle(fontSize: 9, color: axisLabelColor);

    // 计算要显示标签的下标：首点、末点 + 中间均匀采样
    final labelIndices = <int>{};
    if (pointCount <= maxLabels) {
      // 点数少，全部显示
      for (int i = 0; i < pointCount; i++) {
        labelIndices.add(i);
      }
    } else {
      // 首尾必显示，中间均匀取 maxLabels-2 个
      labelIndices.add(0);
      labelIndices.add(pointCount - 1);
      const innerCount = maxLabels - 2;
      for (int j = 1; j <= innerCount; j++) {
        final idx = ((pointCount - 1) * j / (innerCount + 1)).round();
        labelIndices.add(idx);
      }
    }

    final sortedIndices = labelIndices.toList()..sort();
    for (final i in sortedIndices) {
      final label = _xLabel(points[i], range);
      final tp = TextPainter(
        text: TextSpan(text: label, style: xLabelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      double x = coords[i].dx - tp.width / 2;
      x = x.clamp(chartLeft, chartRight - tp.width);
      tp.paint(canvas, Offset(x, chartBottom + 6));
    }
  }

  /// X 轴标签文字
  String _xLabel(ConsumptionPoint p, ConsumptionRange range) {
    switch (range) {
      case ConsumptionRange.today:
        // 半小时粒度，显示 HH:MM
        final h = p.time.hour.toString().padLeft(2, '0');
        final m = p.time.minute.toString().padLeft(2, '0');
        return '$h:$m';
      case ConsumptionRange.week:
      case ConsumptionRange.month:
        // 天粒度，显示 M/D
        return '${p.time.month}/${p.time.day}';
    }
  }

  @override
  bool shouldRepaint(_LineChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.range != range ||
      oldDelegate.isDark != isDark ||
      oldDelegate.activeIndex != activeIndex;
}

/// 时间范围切换按钮组。v4：暗色模式适配。
class _RangeToggle extends StatelessWidget {
  final ConsumptionRange range;
  final ValueChanged<ConsumptionRange> onChanged;

  const _RangeToggle({required this.range, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: ConsumptionRange.values.map((r) {
          final selected = r == range;
          final label = switch (r) {
            ConsumptionRange.today => '今日',
            ConsumptionRange.week => '本周',
            ConsumptionRange.month => '本月',
          };
          if (GlassButtonsTheme.enabledOf(context)) {
            return Semantics(
              selected: selected,
              child: AppGlassButton(
                key: ValueKey('cost-range-${r.name}'),
                label: label,
                onPressed: () => onChanged(r),
                variant: selected
                    ? AppGlassButtonVariant.primary
                    : AppGlassButtonVariant.quiet,
                compact: true,
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                borderRadius: BorderRadius.circular(10),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }
          return Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('cost-range-${r.name}'),
              onTap: () => onChanged(r),
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              child: AnimatedContainer(
                duration: AppMotion.duration(
                  context,
                  const Duration(milliseconds: 170),
                ),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Colors.white
                        : (isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
