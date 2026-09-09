import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../providers/onboarding_provider.dart';

/// 步骤6：成本参数。
///
/// 4 项参数（电费单价 / 机器功率 / 机器损耗率 / 人工时薪），
/// 与耗材成本设置页共享同一组 SharedPreferences key。
/// 预填从现有存储读取，onChanged 实时写回 + 同步到 OnboardingState。
/// 可跳过（留空也可下一步，留空按默认值处理）。
class CostParamsStep extends ConsumerStatefulWidget {
  const CostParamsStep({super.key});

  @override
  ConsumerState<CostParamsStep> createState() => _CostParamsStepState();
}

class _CostParamsStepState extends ConsumerState<CostParamsStep> {
  // 与 filament_cost_screen.dart 保持一致的 SharedPreferences key
  static const _kElecPrice = 'cost_elec_price'; // 电费单价（元/度）
  static const _kPrinterPower = 'cost_printer_power'; // 打印机功率（W）
  static const _kWearRate = 'cost_wear_rate'; // 机器损耗率（元/小时）
  static const _kLaborRate = 'cost_labor_rate'; // 每小时人工费（元/小时）

  // 默认值（与耗材成本页一致）
  static const _defaultElec = 0.6;
  static const _defaultPower = 150.0;
  static const _defaultWear = 0.5;
  static const _defaultLabor = 0.0;

  late final TextEditingController _elecCtrl;
  late final TextEditingController _powerCtrl;
  late final TextEditingController _wearCtrl;
  late final TextEditingController _laborCtrl;

  String? _elecError;
  String? _powerError;
  String? _wearError;
  String? _laborError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _elecCtrl = TextEditingController();
    _powerCtrl = TextEditingController();
    _wearCtrl = TextEditingController();
    _laborCtrl = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _elecCtrl.dispose();
    _powerCtrl.dispose();
    _wearCtrl.dispose();
    _laborCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 预填优先级：OnboardingState.costParams > SharedPreferences > 默认值
    final state = ref.read(onboardingProvider);
    final prefs = await SharedPreferences.getInstance();

    final cp = state.costParams;
    final elec =
        cp?['electricityPrice'] ?? prefs.getDouble(_kElecPrice) ?? _defaultElec;
    final power =
        cp?['machinePower'] ?? prefs.getDouble(_kPrinterPower) ?? _defaultPower;
    final wear =
        cp?['machineLossRate'] ?? prefs.getDouble(_kWearRate) ?? _defaultWear;
    final labor =
        cp?['laborCost'] ?? prefs.getDouble(_kLaborRate) ?? _defaultLabor;

    if (!mounted) return;
    setState(() {
      _elecCtrl.text = _format(elec);
      _powerCtrl.text = _format(power);
      _wearCtrl.text = _format(wear);
      _laborCtrl.text = _format(labor);
      _loaded = true;
    });
    _persistAndSync();
  }

  /// 格式化：整数不显示小数点，否则保留必要小数。
  String _format(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// 解析输入，空值用默认值。
  double _parse(String text, double defaultValue) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return defaultValue;
    return double.tryParse(trimmed) ?? defaultValue;
  }

  /// 校验单项：非负；功率额外要求 >0。
  String? _validate(String text, bool isPower) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null; // 留空可跳过，按默认值
    final v = double.tryParse(trimmed);
    if (v == null) return '请输入有效数字';
    if (v < 0) return '不能为负数';
    if (isPower && v <= 0) return '功率必须大于 0';
    return null;
  }

  Future<void> _persistAndSync() async {
    final elec = _parse(_elecCtrl.text, _defaultElec);
    final power = _parse(_powerCtrl.text, _defaultPower);
    final wear = _parse(_wearCtrl.text, _defaultWear);
    final labor = _parse(_laborCtrl.text, _defaultLabor);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kElecPrice, elec);
    await prefs.setDouble(_kPrinterPower, power);
    await prefs.setDouble(_kWearRate, wear);
    await prefs.setDouble(_kLaborRate, labor);

    ref.read(onboardingProvider.notifier).setCostParams({
      'electricityPrice': elec,
      'machinePower': power,
      'machineLossRate': wear,
      'laborCost': labor,
    });
  }

  void _onChanged() {
    setState(() {
      _elecError = _validate(_elecCtrl.text, false);
      _powerError = _validate(_powerCtrl.text, true);
      _wearError = _validate(_wearCtrl.text, false);
      _laborError = _validate(_laborCtrl.text, false);
    });
    _persistAndSync();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '成本参数',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '这些参数用于打印任务的成本计算。与耗材成本设置页共享，可稍后修改。留空则使用默认值。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        // 2 列网格
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ParamField(
                label: '电费单价',
                suffix: '元/度',
                icon: Icons.bolt_outlined,
                controller: _elecCtrl,
                errorText: _elecError,
                onChanged: _onChanged,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ParamField(
                label: '机器功率',
                suffix: 'W',
                icon: Icons.electrical_services_outlined,
                controller: _powerCtrl,
                errorText: _powerError,
                onChanged: _onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ParamField(
                label: '机器损耗率',
                suffix: '元/小时',
                icon: Icons.precision_manufacturing_outlined,
                controller: _wearCtrl,
                errorText: _wearError,
                onChanged: _onChanged,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ParamField(
                label: '人工时薪',
                suffix: '元/小时',
                icon: Icons.person_outlined,
                controller: _laborCtrl,
                errorText: _laborError,
                onChanged: _onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '默认值：电费 0.6 元/度 · 功率 150W · 损耗率 0.5 元/小时 · 人工 0 元/小时',
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

class _ParamField extends StatelessWidget {
  final String label;
  final String suffix;
  final IconData icon;
  final TextEditingController controller;
  final String? errorText;
  final VoidCallback onChanged;

  const _ParamField({
    required this.label,
    required this.suffix,
    required this.icon,
    required this.controller,
    required this.errorText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: errorText == null ? 36 : 48,
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              suffixText: suffix,
              suffixStyle: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              errorText: errorText,
              errorStyle: const TextStyle(fontSize: 10, height: 1.2),
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
