import 'package:flutter/material.dart';

import '../../core/services/cluster_planning_service.dart';

Future<Map<int, int?>?> showClusterPreparationDialog(
  BuildContext context, {
  required List<ClusterPrinterCandidate> candidates,
  required bool checkingOnly,
  Map<int, int?> initialValues = const {},
}) => showDialog<Map<int, int?>>(
  context: context,
  builder: (_) => ClusterPreparationDialog(
    candidates: candidates,
    checkingOnly: checkingOnly,
    initialValues: initialValues,
  ),
);

class ClusterPreparationDialog extends StatefulWidget {
  const ClusterPreparationDialog({
    super.key,
    required this.candidates,
    required this.checkingOnly,
    this.initialValues = const {},
  });
  final List<ClusterPrinterCandidate> candidates;
  final bool checkingOnly;
  final Map<int, int?> initialValues;
  @override
  State<ClusterPreparationDialog> createState() =>
      _ClusterPreparationDialogState();
}

class _ClusterPreparationDialogState extends State<ClusterPreparationDialog> {
  late final _controllers = {
    for (final candidate in widget.candidates)
      candidate.printerId: TextEditingController(
        text: widget.initialValues[candidate.printerId]?.toString() ?? '',
      ),
  };
  String? _error;
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _confirm() {
    final values = <int, int?>{};
    for (final entry in _controllers.entries) {
      final raw = entry.value.text.trim();
      final value = raw.isEmpty ? null : int.tryParse(raw);
      if ((raw.isNotEmpty &&
              (!RegExp(r'^[0-9]+$').hasMatch(raw) ||
                  value == null ||
                  value > 2678400)) ||
          (!widget.checkingOnly && value == null)) {
        setState(() => _error = '请逐台填写预计准备秒数，确认无需准备时填0');
        return;
      }
      values[entry.key] = value;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('准备耗时'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('取件、换板或换料所需时间。未知请留空。'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  for (final controller in _controllers.values) {
                    controller.text = '0';
                  }
                  _error = null;
                }),
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('全部无需准备'),
              ),
            ),
            const SizedBox(height: 16),
            for (final candidate in widget.candidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: ValueKey('preparation-${candidate.printerId}'),
                  controller: _controllers[candidate.printerId],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: candidate.printerName,
                    suffixText: '秒',
                    hintText: '未知',
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _confirm,
        child: Text(widget.checkingOnly ? '检查条件' : '开始比较'),
      ),
    ],
  );
}
