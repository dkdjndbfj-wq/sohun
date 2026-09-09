import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_update_service.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../core/theme/interaction_effects.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/models/app_auth.dart';
import '../../mobile/ams_template_picker.dart';
import '../../mobile/ams_template_repository.dart';
import '../../mobile/mobile_inventory_sync.dart';
import '../../mobile/mobile_rfid_models.dart';
import '../../mobile/rfid_native_bridge.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../widgets/app_glass_button.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/glass_card.dart';
import '../color_picker/color_picker_panel.dart';
import 'desktop_rfid_bridge.dart';
import 'desktop_rfid_controller.dart';
import 'desktop_serial_transport.dart';
import 'desktop_template_repository.dart';

Future<void> openDesktopRfidWorkbench(
  BuildContext context, {
  // Previews/tests use the real dialog route without a live account/device.
  WidgetBuilder? workbenchBuilder,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: '标签工作台',
  barrierColor: Colors.black.withValues(alpha: .28),
  transitionDuration: AppMotion.duration(
    context,
    const Duration(milliseconds: 180),
  ),
  pageBuilder: (context, _, _) => Dialog(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840, maxHeight: 580),
      child: GlassCard(
        key: const ValueKey('rfid-workbench-dialog'),
        level: GlassLevel.l3,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(20),
        child:
            workbenchBuilder?.call(context) ?? const DesktopRfidWorkbenchHost(),
      ),
    ),
  ),
  transitionBuilder: (_, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
    child: ScaleTransition(
      scale: Tween<double>(
        begin: .97,
        end: 1,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

/// Account/mandatory-update changes destroy the old work session. No result
/// from a previous owner may enter the new owner's queue or inventory.
class DesktopRfidWorkbenchHost extends ConsumerWidget {
  const DesktopRfidWorkbenchHost({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(appAuthProvider);
    final update = ref.watch(appUpdateServiceProvider);
    final session = auth.session;
    if (auth.status == AppAuthStatus.initializing ||
        update.isMandatory ||
        (session != null && session.authRealm != 'personal')) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请先完成登录或更新'),
              const SizedBox(height: 16),
              AppGlassButton(
                label: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }
    final identity =
        '${auth.endpoint}|${session?.user.id}|${session?.user.email.toLowerCase()}|personal';
    return _AccountWorkbench(
      key: ValueKey(identity),
      identity: identity,
      session: session,
    );
  }
}

class _AccountWorkbench extends ConsumerStatefulWidget {
  const _AccountWorkbench({
    super.key,
    required this.identity,
    required this.session,
  });
  final String identity;
  final AppAuthSession? session;
  @override
  ConsumerState<_AccountWorkbench> createState() => _AccountWorkbenchState();
}

class _AccountWorkbenchState extends ConsumerState<_AccountWorkbench> {
  late final DesktopRfidBridge bridge;
  late final DesktopRfidController controller;
  final repository = DesktopTemplateRepository();
  bool _active = true;
  @override
  void initState() {
    super.initState();
    bridge = DesktopRfidBridge(
      transport: MethodChannelDesktopSerialTransport(),
    );
    final dao = ref.read(consumableDaoProvider);
    final session = widget.session;
    final api = ref.read(communityApiProvider);
    final MobileInventorySync sync;
    if (session != null && api is PersonalInventoryApi) {
      sync = AccountMobileInventorySync(
        dao: dao,
        api: api as PersonalInventoryApi,
        session: session,
        ensureSession: () async {
          if (!_active || !mounted) {
            throw const MobileInventoryAccountChangedException();
          }
          final ready = await ref
              .read(appAuthProvider.notifier)
              .ensureValidSession();
          if (!_active ||
              !mounted ||
              ready.user.id != session.user.id ||
              ready.serverBaseUrl != session.serverBaseUrl ||
              ready.user.email.toLowerCase() !=
                  session.user.email.toLowerCase()) {
            throw const MobileInventoryAccountChangedException();
          }
          return ready;
        },
      );
    } else if (session == null) {
      sync = LocalMobileInventorySync(dao);
    } else {
      sync = const _UnavailableInventorySync();
    }
    controller = DesktopRfidController(
      bridge: bridge,
      sync: sync,
      journal: PreferencesDesktopRfidJournal(),
      owner: widget.identity,
      isCurrent: () => _active && mounted,
    );
  }

  @override
  void dispose() {
    _active = false;
    controller.dispose();
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DesktopRfidWorkbench(
    controller: controller,
    repository: repository,
    accountLabel: widget.session?.user.email ?? '本机模式 · 登录后可同步',
    templateOwner: widget.identity,
  );
}

class _UnavailableInventorySync implements MobileInventorySync {
  const _UnavailableInventorySync();
  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    throw StateError('当前服务不支持个人库存同步，未写入其他账号或本机匿名库存');
  }
}

/// Compact desktop view. Real glass actions, status transitions and keyboard
/// focus all use the personal app's existing design/motion system.
class DesktopRfidWorkbench extends StatefulWidget {
  const DesktopRfidWorkbench({
    super.key,
    required this.controller,
    required this.repository,
    required this.accountLabel,
    required this.templateOwner,
  });
  final DesktopRfidController controller;
  final AmsTemplateRepository repository;
  final String accountLabel, templateOwner;
  @override
  State<DesktopRfidWorkbench> createState() => _DesktopRfidWorkbenchState();
}

class _DesktopRfidWorkbenchState extends State<DesktopRfidWorkbench> {
  final _brand = TextEditingController();
  final _model = TextEditingController();
  Color _color = const Color(0xFF23A66B);
  String _colorName = '绿色';
  final _grams = TextEditingController(text: '1000');
  final _quantity = TextEditingController(text: '1');
  final _revision = ValueNotifier<int>(0);
  List<DesktopSerialPort> _ports = [];
  String? _selectedPort, _error;
  int _tab = 2;
  bool _byRemaining = false;
  String _kind = 'cuid';
  bool _typeConfirmed = false, _refreshing = false, _uiBusy = false;
  Timer? _portTimer;
  DesktopRfidController get c => widget.controller;
  DesktopRfidBridge get bridge => c.bridge;
  bool get locked => c.busy || _uiBusy;
  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    unawaited(_refreshPorts());
    _portTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!bridge.connected && !locked) unawaited(_refreshPorts(silent: true));
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _revision.value++;
    c.removeListener(_changed);
    _portTimer?.cancel();
    _revision.dispose();
    for (final field in [_brand, _model, _grams, _quantity]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshPorts({bool silent = false}) async {
    if (_refreshing || bridge.connected) return;
    _refreshing = true;
    try {
      final ports = await bridge.transport.listPorts();
      if (!mounted) return;
      setState(() {
        _ports = ports;
        if (!ports.any((p) => p.port == _selectedPort)) {
          final candidates = ports.where((p) => p.isKitCandidate).toList();
          _selectedPort = candidates.length == 1
              ? candidates.single.port
              : ports.length == 1
              ? ports.single.port
              : null;
        }
      });
    } catch (_) {
      if (mounted && !silent) {
        setState(() => _error = '系统串口服务不可用。此功能需要包含内置通信组件的 Windows 个人版');
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_uiBusy) return;
    setState(() {
      _uiBusy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is DesktopRfidException
              ? error.message
              : error is FormatException
              ? error.message
              : '操作未完成，请检查连接、登录和本机存储；不会自动重写标签',
        );
      }
    } finally {
      if (mounted) setState(() => _uiBusy = false);
    }
  }

  MobileConsumableDraft _draft() => MobileConsumableDraft(
    brand: _brand.text.trim(),
    model: _model.text.trim(),
    color: _color,
    colorName: _colorName,
  );

  Future<void> _pickColor() async {
    final result = await ColorPickerPanel.show(
      context,
      initial: _color,
      initialName: _colorName,
      compact: true,
    );
    if (result == null || !mounted || !c.current) return;
    setState(() {
      _color = result.color;
      _colorName = result.name.isEmpty ? '自定义颜色' : result.name;
    });
  }

  double get grams =>
      _byRemaining ? (double.tryParse(_grams.text.trim()) ?? double.nan) : 1000;
  int get quantity => _byRemaining || _tab != 2
      ? 1
      : (int.tryParse(_quantity.text.trim()) ?? 0);

  Future<void> _selectTemplate() async {
    final choice = await showAmsTemplatePicker(
      context,
      repository: widget.repository,
      ownerAccount: widget.templateOwner,
      accountRevision: _revision,
      onDeleted: c.clearTemplate,
    );
    if (!mounted || !c.current || choice == null) return;
    if (choice.readFromTag) {
      final template = await c.readSource();
      if (template == null || !mounted || !c.current) return;
      await widget.repository.save(
        template,
        ownerAccount: widget.templateOwner,
      );
      if (mounted && c.current) c.selectTemplate(template);
    } else if (choice.template != null) {
      c.selectTemplate(choice.template!);
    }
  }

  Future<void> _write() async {
    final draft = _draft();
    DesktopRfidController.validateDraft(draft, grams, 1);
    if (!_typeConfirmed) {
      throw const DesktopRfidException('type_required', '请先确认目标卡为 CUID/FUID');
    }
    final template = c.template;
    final target = c.target;
    if (template == null || target == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_kind == 'fuid' ? '确认 FUID 的一次 UID 写入' : '确认覆盖这张 CUID'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '目标 ${target.uid} → ${template.uid}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              const Text('将覆盖这张标签的完整数据、UID 和扇区密钥。请只放一张自己的测试卡，保持 USB 与标签位置稳定。'),
              if (_kind == 'fuid')
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('FUID 的制造商区可能只允许写一次；失败也可能导致不可恢复，不能当成可重复擦写卡。'),
                ),
              const SizedBox(height: 12),
              const Text('取消或断线不能回滚已写区块。完整回读通过后才进入待入库列表；这不代表已验证 AMS 接受。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回检查'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认覆盖并校验'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && c.current) {
      await c.writeTarget(
        draft: draft,
        grams: grams,
        kind: _kind,
        confirmed: true,
      );
    }
  }

  Future<void> _close() async {
    if (c.saving) {
      setState(() => _error = '正在保存库存，请等待本笔完成后再关闭');
      return;
    }
    if (c.busy) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('结束当前读写？'),
          content: const Text('写入不能回滚。结束后请单独检查标签，未校验结果不会入库；已有待办保留在本机。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续当前操作'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('结束并关闭'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
      await bridge.cancel();
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !locked,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '标签工作台',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AppGlassButton(
                    label: '帮助',
                    tooltip: '接线与帮助',
                    onPressed: _help,
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    icon: const Icon(Icons.help_outline_rounded, size: 17),
                  ),
                  const SizedBox(width: 6),
                  AppGlassButton(
                    onPressed: _close,
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    tooltip: '关闭工作台',
                    child: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 808),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _connectionCard(),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, size) {
                            final form = _form();
                            final work = Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _operationCard(),
                                const SizedBox(height: 12),
                                _queue(),
                              ],
                            );
                            if (size.maxWidth < 700 ||
                                MediaQuery.textScalerOf(context).scale(14) >
                                    23) {
                              return Column(
                                children: [
                                  form,
                                  const SizedBox(height: 12),
                                  work,
                                ],
                              );
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(width: 250, child: form),
                                const SizedBox(width: 12),
                                Expanded(child: work),
                              ],
                            );
                          },
                        ),
                      ],
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

  Widget _connectionCard() => GlassCard(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  bridge.connected ? Icons.usb_rounded : Icons.usb_off_rounded,
                  size: 19,
                  color: bridge.readerReady
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 9),
                Text(
                  bridge.connecting
                      ? '正在连接…'
                      : bridge.readerReady
                      ? '设备已连接'
                      : bridge.connected
                      ? '读卡器未就绪'
                      : 'USB 套件',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                if (bridge.connected) ...[
                  const SizedBox(width: 10),
                  Tooltip(
                    message: '固件 ${bridge.firmware}',
                    child: Text(
                      bridge.port ?? '',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!bridge.connected)
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        'port-$_selectedPort-${_ports.map((p) => p.port).join()}',
                      ),
                      initialValue: _selectedPort,
                      isExpanded: true,
                      decoration: const InputDecoration(isDense: true),
                      hint: Text(_ports.isEmpty ? '请插入 USB 套件' : '选择设备'),
                      items: [
                        for (final p in _ports)
                          DropdownMenuItem(
                            value: p.port,
                            child: Text(
                              p.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: locked
                          ? null
                          : (value) => setState(() => _selectedPort = value),
                    ),
                  ),
                AppGlassButton(
                  label: bridge.connected ? '断开' : '连接套件',
                  compact: true,
                  variant: bridge.connected
                      ? AppGlassButtonVariant.quiet
                      : AppGlassButtonVariant.primary,
                  onPressed:
                      locked || (!bridge.connected && _selectedPort == null)
                      ? null
                      : () => _run(
                          () => bridge.connected
                              ? bridge.disconnect()
                              : bridge.connect(_selectedPort!),
                        ),
                ),
                if (!bridge.connected)
                  AppGlassButton(
                    tooltip: '刷新设备',
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    onPressed: locked ? null : () => _refreshPorts(),
                    child: const Icon(Icons.refresh_rounded, size: 18),
                  ),
              ],
            ),
          ],
        ),
        if (bridge.connectionMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              bridge.connectionMessage!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );

  Widget _form() => GlassCard(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            FilamentSpoolIcon(color: _color, size: 21),
            const SizedBox(width: 9),
            Text('耗材', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 12),
        _field('品牌', _brand, '例如 SUNLU'),
        const SizedBox(height: 10),
        _field('型号 / 材料', _model, '例如 PLA'),
        const SizedBox(height: 10),
        AppGlassButton(
          key: const ValueKey('rfid-color-picker'),
          tooltip: '选择颜色',
          compact: true,
          variant: AppGlassButtonVariant.secondary,
          onPressed: locked ? null : () => _run(_pickColor),
          child: Row(
            children: [
              Container(
                key: const ValueKey('rfid-selected-color'),
                width: 23,
                height: 23,
                decoration: BoxDecoration(
                  color: _color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _colorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.palette_outlined, size: 18),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassSegmentedSurface(
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('按卷数')),
              ButtonSegment(value: true, label: Text('按余量')),
            ],
            selected: {_byRemaining},
            showSelectedIcon: false,
            onSelectionChanged: locked
                ? null
                : (values) => setState(() => _byRemaining = values.single),
          ),
        ),
        const SizedBox(height: 10),
        if (_byRemaining)
          _field('余量（g）', _grams, '例如 350', numeric: true)
        else if (_tab == 2)
          _field('卷数', _quantity, '1–100', numeric: true),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '标签类型', isDense: true),
          items: const [
            DropdownMenuItem(value: 'cuid', child: Text('CUID')),
            DropdownMenuItem(value: 'fuid', child: Text('FUID')),
          ],
          onChanged: locked
              ? null
              : (value) => setState(() {
                  _kind = value!;
                  _typeConfirmed = false;
                }),
        ),
        const SizedBox(height: 4),
        Tooltip(
          message: '请按购买信息确认。普通 S50 或钥匙扣不能自动当作 CUID/FUID。',
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('确认使用 CUID / FUID'),
            value: _typeConfirmed,
            onChanged: locked
                ? null
                : (v) => setState(() => _typeConfirmed = v == true),
          ),
        ),
      ],
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    bool numeric = false,
  }) => TextField(
    controller: controller,
    enabled: !locked,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
    ),
  );

  bool get _hasStatus =>
      c.working ||
      c.saving ||
      bridge.busy ||
      bridge.connecting ||
      _error != null ||
      !c.journalHealthy;

  Widget _operationCard() => GlassCard(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSegmentedSurface(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 2,
                label: Text('读卡入库'),
                icon: Icon(Icons.nfc_rounded, size: 17),
              ),
              ButtonSegment(
                value: 1,
                label: Text('模板写卡'),
                icon: Icon(Icons.edit_note_rounded, size: 17),
              ),
            ],
            selected: {_tab},
            showSelectedIcon: false,
            onSelectionChanged: locked
                ? null
                : (v) => setState(() {
                    _tab = v.single;
                    _error = null;
                  }),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: AppMotion.duration(
            context,
            const Duration(milliseconds: 220),
          ),
          child: _operationContent(),
        ),
        if (_hasStatus) ...[const SizedBox(height: 14), _status()],
      ],
    ),
  );

  Widget _operationContent() {
    final ready = bridge.readerReady && !locked && c.journalHealthy;
    if (_tab == 1) {
      return Column(
        key: const ValueKey('write'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppGlassButton(
                label: c.template == null ? '选择模板' : '更换模板',
                compact: true,
                onPressed: locked ? null : () => _run(_selectTemplate),
                variant: AppGlassButtonVariant.secondary,
                icon: const Icon(Icons.folder_open_rounded, size: 17),
              ),
              AppGlassButton(
                label: '读取目标',
                compact: true,
                onPressed: ready ? () => _run(c.scanTarget) : null,
                variant: AppGlassButtonVariant.secondary,
                icon: const Icon(Icons.sensors_rounded, size: 17),
              ),
              AppGlassButton(
                label: '写入并校验',
                compact: true,
                onPressed:
                    ready &&
                        c.template != null &&
                        c.target != null &&
                        _typeConfirmed
                    ? () => _run(_write)
                    : null,
                icon: const Icon(Icons.verified_outlined, size: 17),
              ),
            ],
          ),
          if (c.template != null || c.target != null) ...[
            const SizedBox(height: 12),
            Text(
              [
                if (c.template != null) c.template!.name,
                if (c.target != null) '目标 ${c.target!.uid}',
              ].join('  ·  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      );
    }
    return Row(
      key: const ValueKey('scan'),
      children: [
        Expanded(
          child: Text('放上一张标签', style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(width: 12),
        AppGlassButton(
          label: '读取标签',
          compact: true,
          onPressed: ready && _typeConfirmed
              ? () => _run(
                  () => c.enqueueScan(
                    draft: _draft(),
                    grams: grams,
                    kind: _kind,
                    typeConfirmed: _typeConfirmed,
                    mode: RfidReceiptMode.stock,
                    quantity: quantity,
                  ),
                )
              : null,
          icon: const Icon(Icons.sensors_rounded, size: 17),
        ),
      ],
    );
  }

  Widget _status() {
    final active = c.working || bridge.connecting || bridge.busy;
    final label =
        _error ??
        (c.saving
            ? '正在入库…'
            : !c.journalHealthy
            ? c.message!
            : switch (bridge.state) {
                'connecting' => '正在连接设备…',
                'waiting' => '等待标签，请保持贴近',
                'preflight' => '正在检查标签…',
                'writing' => '正在写入，请勿移卡或拔线',
                'awaiting_reselect' => '正在重新识别标签…',
                'verifying' => '正在校验 ${bridge.completed} / 64',
                'cancelling' => '正在停止…',
                _ => '正在处理…',
              });
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:
              (_error == null
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error)
                  .withValues(alpha: .07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label),
            if (active || c.saving) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: bridge.state == 'verifying'
                    ? bridge.completed / 64
                    : !AppMotion.enabled(context)
                    ? 0
                    : null,
                minHeight: 3,
              ),
            ],
            if (bridge.busy && !bridge.connecting && !c.saving)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AppGlassButton(
                    label: '取消操作',
                    compact: true,
                    variant: AppGlassButtonVariant.quiet,
                    onPressed: () => bridge.cancel(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _itemSummary(DesktopRfidQueueItem item) {
    if (item.done) {
      if (item.feedback.contains('换卷')) return '需确认换卷';
      return item.syncPending ? '已入库 · 待同步' : '已入库';
    }
    if (item.feedback.contains('未完成')) return '入库失败 · 可重试';
    return '${item.quantity} 卷 · ${item.grams.toStringAsFixed(0)} g/卷';
  }

  void _itemDetails(DesktopRfidQueueItem item) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${item.draft.brand} ${item.draft.model}'),
      content: Text(
        'UID：${item.uid}\n卡型：${item.kind.toUpperCase()}\n'
        '数量：${item.quantity} 卷 · 每卷 ${item.grams.toStringAsFixed(0)} g\n'
        '${item.writeVerified ? '完整模板与 UID 已校验；AMS 兼容仍需实测' : '只读登记，未改写标签'}\n'
        '${item.feedback}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _queue() {
    final rolls = c.items
        .where((i) => !i.done)
        .fold<int>(0, (total, item) => total + item.quantity);
    return GlassCard(
      key: const ValueKey('rfid-queue-card'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                c.pendingCount == 0 && c.items.isNotEmpty
                    ? '本批已完成'
                    : '待入库${c.pendingCount == 0 ? '' : ' · ${c.pendingCount} 项'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (c.items.isNotEmpty && c.pendingCount == 0)
                    AppGlassButton(
                      label: '新批次',
                      compact: true,
                      variant: AppGlassButtonVariant.secondary,
                      onPressed: locked ? null : () => _run(c.newBatch),
                    ),
                  AppGlassButton(
                    label: rolls == 0 ? '确认入库' : '入库 $rolls 卷',
                    compact: true,
                    onPressed: locked || c.pendingCount == 0
                        ? null
                        : () => _run(c.commit),
                    icon: const Icon(Icons.check_rounded, size: 17),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (c.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  '暂无标签',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else
            SizedBox(
              key: const ValueKey('rfid-queue-list'),
              height:
                  (c.items.length *
                          56.0 *
                          MediaQuery.textScalerOf(context).scale(14) /
                          14)
                      .clamp(56.0, _tab == 1 ? 176.0 : 224.0),
              child: ListView.separated(
                itemCount: c.items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = c.items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        FilamentSpoolIcon(color: item.draft.color, size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => _itemDetails(item),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item.draft.brand} ${item.draft.model}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _itemSummary(item),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (item.writeVerified)
                          const Tooltip(
                            message: '写卡已校验',
                            child: Icon(Icons.verified_outlined, size: 17),
                          ),
                        if (!item.done)
                          AppGlassButton(
                            tooltip: '取消此条，不增加库存',
                            compact: true,
                            variant: AppGlassButtonVariant.quiet,
                            onPressed: locked
                                ? null
                                : () => _run(() => c.remove(item)),
                            child: const Icon(Icons.close_rounded, size: 17),
                          )
                        else
                          Tooltip(
                            message: item.feedback,
                            child: const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 19,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  void _help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('套件连接与接线'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('库存归属：${widget.accountLabel}'),
              const SizedBox(height: 10),
              const Text('内置串口 · 115200 / 8N1。模板与密钥仅加密保存在本机，不随库存上传。'),
              const SizedBox(height: 10),
              const Text(
                '成品套件：接入 USB → 连接套件 → 放入一张标签。正常使用不需要 Arduino、Python 或串口助手。',
              ),
              const SizedBox(height: 14),
              Text(
                '自己组装 · 先拔掉 USB 再接线',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(),
                  1: FlexColumnWidth(),
                },
                children: [
                  for (final row in const [
                    ['RC522 引脚', 'ESP32 引脚'],
                    ['3.3V', '3V3（不能接 VIN / 5V）'],
                    ['GND', 'GND'],
                    ['SDA / SS', 'GPIO27 / D27'],
                    ['SCK', 'GPIO18 / D18'],
                    ['MOSI', 'GPIO23 / D23'],
                    ['MISO', 'GPIO19 / D19'],
                    ['RST', 'GPIO22 / D22'],
                    ['IRQ', '不接'],
                  ])
                    TableRow(
                      children: [
                        for (final value in row)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Text(value),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '按实物 GPIO 丝印接线，不按排针第几脚数。这里 RC522 的 SDA 是 SPI 片选，不是 I²C 数据线。适用于图片中的经典 ESP32 30Pin 板，不套用于 C3 / S3。',
              ),
              const SizedBox(height: 14),
              const Text(
                '找不到设备：确认 USB 数据线、CH340 驱动和供电。连接但未就绪：检查配套固件和 RC522 接线。串口被占用：关闭串口助手或烧录程序后重试。',
              ),
              const SizedBox(height: 10),
              const Text(
                '普通 S50 不保证可改 UID。FUID 可能一次写入后锁定；中断不能回滚。软件回读成功不等于 AMS 已接受，发货前需要逐台硬件验收。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
