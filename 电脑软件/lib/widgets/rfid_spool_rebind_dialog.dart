import 'package:flutter/material.dart';

import '../data/database/database.dart';
import '../data/models/rfid_tag_identity.dart';

Future<bool> showRfidSpoolRebindDialog(
  BuildContext context, {
  required Consumable item,
  required Future<void> Function(String uid, String type) save,
  Future<String?> Function()? scan,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RebindDialog(item: item, save: save, scan: scan),
    ) ??
    false;

class _RebindDialog extends StatefulWidget {
  const _RebindDialog({required this.item, required this.save, this.scan});
  final Consumable item;
  final Future<void> Function(String uid, String type) save;
  final Future<String?> Function()? scan;
  @override
  State<_RebindDialog> createState() => _RebindDialogState();
}

class _RebindDialogState extends State<_RebindDialog> {
  final _uid = TextEditingController();
  final _form = GlobalKey<FormState>();
  String? _type;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _uid.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('旧余料换绑新标签'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '请将另一张未登记的 CUID/FUID 标签贴到这卷余料上。现有 ${widget.item.remainingGrams.toStringAsFixed(1)} g 余量、库存卷号和消耗记录会保留，原标签继续对应已换入的新卷。',
                ),
                const SizedBox(height: 12),
                const Text('此处登记标签归属。如需 AMS 识别，请先在写卡页为新标签准备兼容模板。已登录账号需联网完成换绑。'),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('rebind-tag-uid'),
                  controller: _uid,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '新标签 UID（8 位十六进制）',
                  ),
                  validator: (value) =>
                      RegExp(
                        r'^[0-9A-F]{8}$',
                      ).hasMatch(normalizeRfidTagUid(value ?? ''))
                      ? null
                      : '请输入新标签的 8 位十六进制 UID',
                ),
                DropdownButtonFormField<String>(
                  key: const ValueKey('rebind-tag-type'),
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '标签类型'),
                  validator: (value) =>
                      value == null ? '请按实际卡型选择 CUID 或 FUID' : null,
                  items: const [
                    DropdownMenuItem(value: 'CUID', child: Text('CUID')),
                    DropdownMenuItem(value: 'FUID', child: Text('FUID')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _type = value!),
                ),
                if (widget.scan != null)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final uid = await widget.scan!();
                            if (uid != null && mounted)
                              _uid.text = normalizeRfidTagUid(uid);
                          }),
                    icon: const Icon(Icons.nfc),
                    label: const Text('扫描新标签'),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (!_form.currentState!.validate()) return;
                  await _run(() async {
                    await widget.save(normalizeRfidTagUid(_uid.text), _type!);
                    if (mounted) {
                      // PopScope must rebuild before programmatic pop on Android.
                      setState(() => _busy = false);
                      await WidgetsBinding.instance.endOfFrame;
                      if (context.mounted) Navigator.pop(context, true);
                    }
                  });
                },
          child: Text(_busy ? '处理中…' : '确认换绑'),
        ),
      ],
    ),
  );
}
