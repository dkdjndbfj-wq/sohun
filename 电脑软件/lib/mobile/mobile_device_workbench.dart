import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/models/personal_device.dart';
import '../data/models/printer_fault.dart';
import '../providers/device_workbench_provider.dart';
import '../features/diagnostics/printer_fault_center.dart'
    show PrinterFaultCard;
import 'device_tag_nfc.dart';
import 'mobile_printer_faults.dart';

class MobileDeviceWorkbenchPage extends ConsumerStatefulWidget {
  const MobileDeviceWorkbenchPage({super.key, required this.onAccountTap});
  final VoidCallback onAccountTap;
  @override
  ConsumerState<MobileDeviceWorkbenchPage> createState() =>
      _MobileDeviceWorkbenchPageState();
}

class _MobileDeviceWorkbenchPageState
    extends ConsumerState<MobileDeviceWorkbenchPage> {
  String? _selectedKey, _error, _owner;
  bool _busy = false, _showArchived = false;
  int _operation = 0;
  late final DeviceTagNfc _nfc;
  @override
  void initState() {
    super.initState();
    _nfc = ref.read(deviceTagNfcProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumeRequest();
    });
  }

  @override
  void dispose() {
    ++_operation;
    unawaited(_nfc.cancel());
    super.dispose();
  }

  void _message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _settledDialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    return result;
  }

  void _consumeRequest() {
    final token = ref.read(deviceTagOpenRequestProvider);
    if (token != null && ref.read(deviceWorkbenchProvider).owner != null)
      unawaited(_resolve(token));
  }

  Future<void> _resolve(String token) async {
    final operation = ++_operation;
    await ref.read(deviceTagNfcProvider).cancel();
    if (!mounted || operation != _operation) return;
    setState(() {
      _busy = true;
      _error = null;
      _selectedKey = null;
    });
    try {
      final device = await ref
          .read(deviceWorkbenchProvider.notifier)
          .resolve(token);
      if (!mounted || operation != _operation) return;
      setState(() => _selectedKey = device.printerKey);
    } catch (error) {
      if (mounted && operation == _operation) setState(() => _error = '$error');
    } finally {
      if (mounted && operation == _operation) setState(() => _busy = false);
    }
  }

  Future<void> _readTag() async {
    final operation = ++_operation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final nfc = ref.read(deviceTagNfcProvider);
      if (!await nfc.isAvailable() || !await nfc.isEnabled())
        throw StateError('请使用支持 NFC 的手机并开启 NFC');
      if (!mounted || operation != _operation) return;
      _message('请靠近打印机上的 NTAG213 设备标签');
      final result = await nfc.read();
      if (!mounted || operation != _operation) return;
      if (result is DeviceTagReadSuccess) {
        final previous = ref.read(deviceTagOpenRequestProvider);
        ref.read(deviceTagOpenRequestProvider.notifier).state =
            result.deviceToken;
        if (previous == result.deviceToken) await _resolve(result.deviceToken);
      } else if (result is DeviceTagReadFailure) {
        throw StateError(result.message);
      }
    } catch (error) {
      if (mounted && operation == _operation) setState(() => _error = '$error');
    } finally {
      if (mounted && operation == _operation) setState(() => _busy = false);
    }
  }

  Future<void> _writeTag(PersonalDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('为${device.name}制作设备标签'),
        content: const Text('将覆盖 NTAG213 中现有的内容。请确认这张标签用于当前打印机。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认并写入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final operation = ++_operation,
        owner = ref.read(deviceWorkbenchProvider).owner;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = ref.read(deviceWorkbenchProvider.notifier);
      // Re-authorize before touching hardware, including after tag rotation.
      final authorized = await controller.resolve(
        device.deviceToken,
        allowCached: false,
      );
      if (!mounted ||
          operation != _operation ||
          owner != ref.read(deviceWorkbenchProvider).owner)
        return;
      final nfc = ref.read(deviceTagNfcProvider);
      if (!await nfc.isAvailable() || !await nfc.isEnabled())
        throw StateError('请开启手机 NFC');
      if (!mounted || operation != _operation) return;
      _message('请贴近未锁定的 NTAG213，并保持到回读校验完成');
      final result = await nfc.write(authorized.deviceToken);
      if (!mounted ||
          operation != _operation ||
          owner != ref.read(deviceWorkbenchProvider).owner)
        return;
      if (result is DeviceTagWriteSuccess && result.verified) {
        await controller.recordTagWrite(authorized, result);
        _message('设备标签已写入并校验，可贴在打印机上');
      } else if (result is DeviceTagWriteFailure) {
        throw StateError(result.message);
      } else {
        throw StateError('标签校验未完成，请重新检查');
      }
    } catch (error) {
      if (mounted && operation == _operation) setState(() => _error = '$error');
    } finally {
      if (mounted && operation == _operation) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    ++_operation;
    await ref.read(deviceTagNfcProvider).cancel();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editCamera(PersonalDevice device) async {
    final owner = ref.read(deviceWorkbenchProvider).owner;
    final input = TextEditingController(text: device.cameraUrl ?? '');
    try {
      final value = await _settledDialog<String>(
        (ctx) => AlertDialog(
          title: const Text('摄像头入口'),
          content: TextField(
            controller: input,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'HTTPS 摄像头页面或直播链接',
              helperText: '留空可移除；设备标签中不保存此链接',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, input.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (value == null || !mounted) return;
      if (owner != ref.read(deviceWorkbenchProvider).owner) {
        throw StateError('账号已切换，请重新打开设备');
      }
      await ref.read(deviceWorkbenchProvider.notifier).updateDevice(
        device.printerKey,
        {'cameraUrl': value.isEmpty ? null : value},
      );
    } catch (error) {
      _message('$error');
    } finally {
      input.dispose();
    }
  }

  Future<void> _changeSharing(PersonalDevice device) async {
    final owner = ref.read(deviceWorkbenchProvider).owner;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(device.archived ? '恢复设备共享' : '停止设备共享'),
        content: const Text('已有设备标签会失效，恢复后需要重新制作标签。维护记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      if (owner != ref.read(deviceWorkbenchProvider).owner) {
        throw StateError('账号已切换，请重新打开设备');
      }
      await ref.read(deviceWorkbenchProvider.notifier).updateDevice(
        device.printerKey,
        {'archived': !device.archived},
      );
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _rotate(PersonalDevice device) async {
    final owner = ref.read(deviceWorkbenchProvider).owner;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('使旧设备标签失效'),
        content: const Text('丢失或更换标签时可使用此操作。之后需要重新写入设备标签。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('更新标签标识'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      if (owner != ref.read(deviceWorkbenchProvider).owner) {
        throw StateError('账号已切换，请重新打开设备');
      }
      await ref
          .read(deviceWorkbenchProvider.notifier)
          .rotateTag(device.printerKey);
      _message('旧标签已失效，请制作新标签');
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _maintenance(
    PersonalDevice device, {
    PrinterFaultRecord? fault,
  }) async {
    final input = TextEditingController();
    var kind = fault == null ? 'inspection' : 'repair';
    var performed = DateTime.now();
    DateTime? due;
    var saving = false;
    String? error;
    final owner = ref.read(deviceWorkbenchProvider).owner;
    try {
      await _settledDialog<void>(
        (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text('记录${device.name}的维护'),
            content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (fault != null) Text(fault.title),
                    DropdownButtonFormField<String>(
                      initialValue: kind,
                      decoration: const InputDecoration(labelText: '维护项目'),
                      items: [
                        for (final type in deviceMaintenanceTypes.entries)
                          DropdownMenuItem(
                            value: type.key,
                            child: Text(type.value),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) => update(() => kind = value!),
                    ),
                    TextField(
                      controller: input,
                      maxLength: 2000,
                      minLines: 2,
                      maxLines: 4,
                      enabled: !saving,
                      decoration: const InputDecoration(labelText: '处理情况与备注'),
                    ),
                    TextButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final day = await showDatePicker(
                                context: ctx,
                                initialDate: performed,
                                firstDate: DateTime(2000),
                                lastDate: DateTime.now(),
                              );
                              if (day != null && ctx.mounted)
                                update(() => performed = day);
                            },
                      child: Text('维护日期：${_day(performed)}'),
                    ),
                    TextButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final day = await showDatePicker(
                                context: ctx,
                                initialDate:
                                    due ??
                                    DateTime.now().add(
                                      const Duration(days: 30),
                                    ),
                                firstDate: performed,
                                lastDate: DateTime.now().add(
                                  const Duration(days: 3650),
                                ),
                              );
                              if (day != null && ctx.mounted)
                                update(() => due = day);
                            },
                      child: Text(
                        due == null ? '设置下次维护日期（可选）' : '下次维护：${_day(due!)}',
                      ),
                    ),
                    if (due != null)
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => update(() => due = null),
                        child: const Text('取消维护提醒'),
                      ),
                    if (error != null)
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        update(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          if (owner != ref.read(deviceWorkbenchProvider).owner)
                            throw StateError('账号已切换，请重新打开设备');
                          await ref
                              .read(deviceWorkbenchProvider.notifier)
                              .addMaintenance(
                                key: device.printerKey,
                                kind: kind,
                                notes: input.text,
                                performedAt: performed,
                                nextDueAt: due,
                                faultEventId: fault?.eventId,
                              );
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (failure) {
                          if (ctx.mounted)
                            update(() {
                              saving = false;
                              error = '$failure';
                            });
                        }
                      },
                child: Text(saving ? '正在保存…' : '保存维护记录'),
              ),
            ],
          ),
        ),
      );
    } finally {
      input.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceWorkbenchProvider);
    ref.listen(deviceTagOpenRequestProvider, (_, token) {
      if (token != null && state.owner != null) unawaited(_resolve(token));
    });
    ref.listen(deviceWorkbenchProvider.select((s) => s.owner), (_, owner) {
      if (_owner != owner) {
        _owner = owner;
        ++_operation;
        unawaited(ref.read(deviceTagNfcProvider).cancel());
        setState(() {
          _selectedKey = null;
          _error = null;
          _busy = false;
        });
        if (owner != null) _consumeRequest();
      }
    });
    final selected = state.devices
        .where((d) => d.printerKey == _selectedKey)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text(selected?.name ?? '设备工作台'),
        leading: BackButton(
          onPressed: () {
            if (_selectedKey != null) {
              ref.read(deviceTagOpenRequestProvider.notifier).state = null;
              setState(() => _selectedKey = null);
            } else {
              Navigator.maybePop(context);
            }
          },
        ),
        actions: [
          IconButton(
            tooltip: '刷新设备',
            onPressed: state.busy
                ? null
                : () => ref.read(deviceWorkbenchProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: state.owner == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.devices, size: 46),
                      const SizedBox(height: 16),
                      const Text(
                        '登录与桌面相同的 sohun 个人账号，查看设备并制作 NTAG213 设备标签。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: widget.onAccountTap,
                        child: const Text('登录 sohun'),
                      ),
                    ],
                  ),
                ),
              )
            : RefreshIndicator(
                onRefresh: () async {
                  await ref.read(deviceWorkbenchProvider.notifier).refresh();
                },
                child: ListView(
                  padding: const EdgeInsets.all(18),
                  children: [
                    if (_busy || state.busy) const LinearProgressIndicator(),
                    if (_busy)
                      TextButton(
                        onPressed: _cancel,
                        child: const Text('取消设备标签操作'),
                      ),
                    if (_error != null) _notice(_error!, error: true),
                    if (state.error != null) _notice(state.error!),
                    if (selected == null && _selectedKey != null)
                      const Text('该设备已不可用，请返回设备列表重新核对。'),
                    if (_selectedKey == null) ..._deviceList(state),
                    if (selected != null) ..._deviceDetails(selected, state),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _notice(String message, {bool error = false}) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: TextStyle(
          color: error ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    ),
  );
  List<Widget> _deviceList(DeviceWorkbenchState state) {
    final devices = state.devices
        .where((d) => _showArchived || !d.archived)
        .toList();
    final due = dueDeviceMaintenance(state.records, DateTime.now());
    return [
      const Text(
        '碰一碰，打开眼前这台打印机',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text('设备标签用于查看机器、处理故障和记录保养。首次使用，请在桌面设置中开启“共享设备状态到手机”。'),
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: _busy ? null : _readTag,
        icon: const Icon(Icons.nfc),
        label: const Text('扫描 NTAG213 设备标签'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('显示已停止共享的设备'),
        value: _showArchived,
        onChanged: (v) => setState(() => _showArchived = v),
      ),
      if (devices.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('暂时没有设备。连接桌面打印机并启用共享后，下拉刷新。'),
        ),
      for (final d in devices)
        Card(
          child: ListTile(
            leading: Icon(d.archived ? Icons.link_off : Icons.print_outlined),
            title: Text(d.name),
            subtitle: Text(
              '${d.model} · ${d.archived
                  ? '已停止共享'
                  : state.error == null && d.isFresh(DateTime.now())
                  ? '在线'
                  : '离线或状态待更新'}${due.any((r) => r.printerKey == d.printerKey) ? '\n有维护项目到期' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() {
              _selectedKey = d.printerKey;
              _error = null;
            }),
          ),
        ),
    ];
  }

  List<Widget> _deviceDetails(
    PersonalDevice device,
    DeviceWorkbenchState state,
  ) {
    final fresh = state.error == null && device.isFresh(DateTime.now());
    final records = state.records
        .where((r) => r.printerKey == device.printerKey)
        .toList();
    final due = dueDeviceMaintenance(records, DateTime.now());
    final faults = ref
        .watch(mobilePrinterFaultProvider)
        .records
        .where((f) => f.printerKey == device.printerKey)
        .toList();
    return [
      Text(device.model, style: Theme.of(context).textTheme.titleMedium),
      if (device.archived)
        _notice('设备已停止共享。旧标签已失效，恢复后请重新制作。')
      else
        _notice(
          '${fresh ? '在线 · ${_stateLabel(device.state)}' : '最后保存的状态 · 当前未确认在线'}\n设备上报：${_time(device.observedAt)}',
        ),
      if (!device.archived) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.taskName?.isNotEmpty == true
                      ? device.taskName!
                      : '没有已上报的任务',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (device.progress != null)
                  LinearProgressIndicator(
                    value: device.progress!.clamp(0, 100) / 100,
                  ),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text(
                      '进度 ${device.progress == null ? '未知' : '${device.progress}%'}',
                    ),
                    Text(
                      '剩余 ${device.remainingMinutes == null ? '未知' : '${device.remainingMinutes} 分钟'}',
                    ),
                    Text(
                      '喷嘴 ${device.nozzleTemperature?.toStringAsFixed(0) ?? '未知'}℃',
                    ),
                    Text(
                      '热床 ${device.bedTemperature?.toStringAsFixed(0) ?? '未知'}℃',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _writeTag(device),
              icon: const Icon(Icons.nfc),
              label: const Text('制作设备标签'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _maintenance(device),
              icon: const Icon(Icons.build_outlined),
              label: const Text('记录保养 / 巡检'),
            ),
            if (device.cameraUrl != null)
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(device.cameraUrl!);
                  if (uri == null ||
                      uri.scheme != 'https' ||
                      uri.userInfo.isNotEmpty) {
                    _message('摄像头入口无效，请重新设置');
                    return;
                  }
                  if (!await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  ))
                    _message('无法打开摄像头入口');
                },
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('查看摄像头'),
              ),
          ],
        ),
        TextButton(
          onPressed: () => _editCamera(device),
          child: Text(device.cameraUrl == null ? '设置可用的摄像头入口' : '修改摄像头入口'),
        ),
        if (device.cameraUrl == null) const Text('尚未配置手机可访问的摄像头页面或直播链接。'),
        const SizedBox(height: 18),
        Text('设备故障', style: Theme.of(context).textTheme.titleLarge),
        if (faults.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('没有同步到这台设备的故障记录'),
          ),
        for (final fault in faults)
          Column(
            children: [
              PrinterFaultCard(
                fault: fault,
                onRead: () => ref
                    .read(mobilePrinterFaultProvider.notifier)
                    .markRead(fault),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _maintenance(device, fault: fault),
                  child: const Text('记录处理情况'),
                ),
              ),
            ],
          ),
      ],
      const SizedBox(height: 18),
      Text('维护与巡检记录', style: Theme.of(context).textTheme.titleLarge),
      for (final item in due)
        _notice('${item.label}已到期：${_day(item.nextDueAt!)}'),
      if (records.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('还没有维护记录'),
        ),
      for (final record in records)
        Card(
          child: ListTile(
            title: Text(
              '${record.label} · ${_day(record.performedAt)}${record.pending ? ' · 待同步' : ''}',
            ),
            subtitle: Text(
              '${record.notes}${record.nextDueAt == null ? '' : '\n下次维护：${_day(record.nextDueAt!)}'}',
            ),
          ),
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: [
          if (!device.archived)
            TextButton(
              onPressed: () => _rotate(device),
              child: const Text('使旧设备标签失效'),
            ),
          TextButton(
            onPressed: () => _changeSharing(device),
            child: Text(device.archived ? '恢复设备共享' : '停止设备共享'),
          ),
        ],
      ),
    ];
  }
}

String _day(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _time(DateTime date) {
  final d = date.toLocal();
  return '${_day(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String _stateLabel(String state) =>
    const {
      'running': '打印中',
      'pause': '已暂停',
      'finish': '已完成',
      'idle': '空闲',
      'prepare': '准备中',
      'failed': '任务异常',
      'init': '初始化',
    }[state] ??
    '状态待确认';
