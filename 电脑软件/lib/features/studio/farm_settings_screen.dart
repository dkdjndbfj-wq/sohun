import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/studio_provider.dart';
import 'farm_ui/farm_design.dart';
import 'farm_ui/farm_feedback.dart';

final farmLowStockThresholdProvider = FutureProvider<double>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getInt('farm_low_stock_threshold_grams') ?? 200).toDouble();
});

/// Settings deliberately scoped to the farm workspace.
///
/// The personal settings sheet contains slicer/account preferences. Farm
/// operators need a different contract: queue policy, stock rules, camera
/// access and the safe completion/collection flow live here instead.
class FarmSettingsScreen extends ConsumerStatefulWidget {
  const FarmSettingsScreen({super.key});

  @override
  ConsumerState<FarmSettingsScreen> createState() => _FarmSettingsScreenState();
}

class _FarmSettingsScreenState extends ConsumerState<FarmSettingsScreen> {
  static const _lowStockKey = 'farm_low_stock_threshold_grams';
  static const _cameraPortalKey = 'farm_camera_portal_enabled';
  final _threshold = TextEditingController(text: '200');
  bool _cameraPortal = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _threshold.text = '${prefs.getInt(_lowStockKey) ?? 200}';
      _cameraPortal = prefs.getBool(_cameraPortalKey) ?? true;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      children: [
        const FarmPageHeader(
          title: '农场设置',
          subtitle: '仅配置生产农场，不修改普通用户的库存、切片和账号设置。',
        ),
        const SizedBox(height: 18),
        _FarmSettingsSection(
          title: '库存与分派规则',
          icon: Icons.inventory_2_outlined,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('默认单卷重量'),
              subtitle: const Text('农场每次换料按 1kg 物理卷计算；部分卷可在库存中修改剩余克数。'),
              trailing: const Chip(label: Text('1000 g')),
            ),
            TextField(
              controller: _threshold,
              enabled: _loaded,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: '低库存提醒阈值',
                  suffixText: 'g',
                  prefixIcon: Icon(Icons.warning_amber_outlined)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _FarmSettingsSection(
          title: '摄像头与客户门户',
          icon: Icons.videocam_outlined,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许订单用户查看打印视频'),
              subtitle: const Text('农场内部摄像头占用状态始终可见；关闭后不会创建客户门户推流。'),
              value: _cameraPortal,
              onChanged: _loaded
                  ? (value) => setState(() => _cameraPortal = value)
                  : null,
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('摄像头占用原则'),
              subtitle: Text('一台打印机同一时刻只允许一个订单视频会话；没有客户观看时不会占用推流资源。'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: !_loaded || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 17),
            label: const Text('保存农场设置'),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final threshold = double.tryParse(_threshold.text.trim());
    if (threshold == null || threshold < 0 || threshold > 1000) {
      showSnack(context, '低库存阈值必须是 0-1000g', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lowStockKey, threshold.round());
      await prefs.setBool(_cameraPortalKey, _cameraPortal);
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'farm_settings.updated',
        entityType: 'workspace',
        entityId: 'farm_settings',
        summary:
            '保存农场设置：低库存阈值 ${threshold.round()}g，客户摄像头${_cameraPortal ? '开启' : '关闭'}',
      );
      if (mounted) {
        ref.invalidate(farmLowStockThresholdProvider);
        showSnack(context, '农场设置已保存');
      }
    } catch (error) {
      if (mounted) showSnack(context, '农场设置保存失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _FarmSettingsSection extends StatelessWidget {
  const _FarmSettingsSection({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 9),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}
