import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/mifu_client.dart';

Future<void> showClusterOutcomeDialog(
  BuildContext context, {
  required MifuClient client,
  required String plateId,
  required String plateName,
  required Map<String, String> visiblePrinters,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ClusterOutcomeDialog(
    client: client,
    plateId: plateId,
    plateName: plateName,
    visiblePrinters: visiblePrinters,
  ),
);

/// Manual evidence only. Completion and inspection are independent observations.
class ClusterOutcomeDialog extends StatefulWidget {
  const ClusterOutcomeDialog({
    super.key,
    required this.client,
    required this.plateId,
    required this.plateName,
    required this.visiblePrinters,
  });
  final MifuClient client;
  final String plateId, plateName;
  final Map<String, String> visiblePrinters;
  @override
  State<ClusterOutcomeDialog> createState() => _ClusterOutcomeDialogState();
}

class _ClusterOutcomeDialogState extends State<ClusterOutcomeDialog> {
  static const executionLabels = {
    'unknown': '状态未知',
    'queued': '等待打印',
    'running': '打印中',
    'paused': '暂停',
    'completed': '已完成',
    'failed': '失败',
    'cancelled': '已取消',
  };
  static const qualityLabels = {
    '': '未填写',
    'not_inspected': '尚未质检',
    'unknown': '无法判断',
    'pass': '合格',
    'rework': '需要返工',
    'reject': '不合格',
  };
  static const defectLabels = {
    'warping': '翘曲',
    'stringing': '拉丝',
    'layer_shift': '层偏移',
    'under_extrusion': '挤出不足',
    'dimensions': '尺寸',
    'surface': '表面',
    'missing_part': '缺件',
    'support': '支撑',
    'adhesion': '粘附',
    'other': '其他',
  };
  final _form = GlobalKey<FormState>();
  final _duration = TextEditingController(), _grams = TextEditingController();
  final _percent = TextEditingController(), _score = TextEditingController();
  final _notes = TextEditingController(), _reason = TextEditingController();
  final _evidence = TextEditingController();
  final _actor = 'desktop-${const Uuid().v4()}';
  MifuRecordHistory? _history;
  String? _recordId, _error, _message;
  String _attemptId = const Uuid().v4(), _kind = 'execution';
  String _execution = 'unknown', _quality = '', _failure = '';
  DateTime? _started, _ended, _inspected;
  String? _originalInspectorId;
  bool _newInspection = false;
  final _defects = <String>{};
  bool _loading = true, _saving = false, _correction = false;
  bool _historyFresh = false;
  Map<String, dynamic>? _pending;

  Map<String, dynamic>? get _record =>
      _history?.records.where((r) => r['recordId'] == _recordId).firstOrNull;
  List<Map<String, dynamic>> get _attempts =>
      _history?.attempts.where((a) => a['recordId'] == _recordId).toList() ??
      [];
  Map<String, dynamic>? get _attempt =>
      _attempts.where((a) => a['attemptId'] == _attemptId).firstOrNull;
  bool get _locked => _saving || _pending != null || !_historyFresh;
  bool get _inspection => ['pass', 'rework', 'reject'].contains(_quality);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _duration,
      _grams,
      _percent,
      _score,
      _notes,
      _reason,
      _evidence,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool reloadSaved = false}) async {
    setState(() {
      _loading = true;
      _historyFresh = false;
      _error = null;
    });
    try {
      final history = await widget.client.queryRecords(
        plateId: widget.plateId,
        candidateIds: widget.visiblePrinters.keys.toSet(),
      );
      if (!mounted) return;
      setState(() {
        _history = history;
        _historyFresh = true;
        if (!history.records.any((r) => r['recordId'] == _recordId)) {
          _recordId = history.records.firstOrNull?['recordId'] as String?;
          _resetAttempt();
        } else if (reloadSaved) {
          _loadPayload(_attempt);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _resetAttempt([Map<String, dynamic>? attempt]) {
    _attemptId = attempt?['attemptId'] as String? ?? const Uuid().v4();
    _kind = 'execution';
    _correction = false;
    _reason.clear();
    _loadPayload(attempt);
  }

  void _loadPayload(Map<String, dynamic>? attempt) {
    final e = attempt?['execution'] as Map?;
    final q = attempt?['quality'] as Map?;
    _execution = e?['status'] as String? ?? 'unknown';
    _quality = q?['status'] as String? ?? '';
    _failure = e?['failureCategory'] as String? ?? '';
    _started = DateTime.tryParse(e?['startedAt'] as String? ?? '');
    _ended = DateTime.tryParse(e?['endedAt'] as String? ?? '');
    _inspected = DateTime.tryParse(q?['inspectedAt'] as String? ?? '');
    _originalInspectorId = q?['inspectorId'] as String?;
    _newInspection = false;
    _duration.text = e?['actualDurationSeconds']?.toString() ?? '';
    _grams.text = e?['materialUsedGrams']?.toString() ?? '';
    _percent.text = e?['completionPercent']?.toString() ?? '';
    _evidence.text = e?['failureEvidence'] as String? ?? '';
    _score.text = q?['qualityScore']?.toString() ?? '';
    _notes.text = q?['notes'] as String? ?? '';
    _defects
      ..clear()
      ..addAll((q?['defectCodes'] as List? ?? []).whereType<String>());
  }

  String _dateText(DateTime? value) =>
      value == null ? '未记录' : value.toLocal().toString().substring(0, 16);

  Future<void> _pickDate(
    DateTime? current,
    ValueChanged<DateTime?> update,
  ) async {
    final now = DateTime.now();
    final earliest = DateTime(2000);
    final local = current?.toLocal() ?? now;
    // Old imported history remains intact; only constrain the picker viewport.
    final initial = local.isBefore(earliest)
        ? earliest
        : local.isAfter(now)
        ? now
        : local;
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: earliest,
      lastDate: now,
      helpText: '选择实际发生日期',
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current?.toLocal() ?? now),
      helpText: '选择实际发生时间',
    );
    if (time == null || !mounted) return;
    setState(
      () => update(
        DateTime(day.year, day.month, day.day, time.hour, time.minute),
      ),
    );
  }

  Widget _dateField(
    String label,
    DateTime? value,
    ValueChanged<DateTime?> update,
  ) => Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _locked ? null : () => _pickDate(value, update),
          icon: const Icon(Icons.event_outlined, size: 17),
          label: Text('$label：${_dateText(value)}'),
        ),
      ),
      IconButton(
        tooltip: '清除$label',
        onPressed: _locked || value == null
            ? null
            : () => setState(() => update(null)),
        icon: const Icon(Icons.clear, size: 18),
      ),
    ],
  );

  Widget _numberField(
    String label,
    TextEditingController controller,
    double max,
  ) => TextFormField(
    controller: controller,
    enabled: !_locked,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, hintText: '未测量请留空'),
    validator: (value) {
      if (value == null || value.trim().isEmpty) return null;
      final number = double.tryParse(value.trim());
      return number == null || !number.isFinite || number < 0 || number > max
          ? '请输入 0–$max 的有效数值'
          : null;
    },
  );

  Map<String, dynamic> _buildEvent() {
    final record = _record;
    if (record == null) throw const MifuException('请先选择已记录的设备选择');
    final now = DateTime.now().toUtc();
    num? number(TextEditingController c) =>
        c.text.trim().isEmpty ? null : num.parse(c.text.trim());
    String? text(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    String? date(DateTime? value) => value?.toUtc().toIso8601String();
    if ([
      _started,
      _ended,
      _inspected,
    ].whereType<DateTime>().any((d) => d.isAfter(now))) {
      throw const MifuException('实际发生时间不能在未来');
    }
    final previous = _attempt?['${_kind}EventId'];
    if (_correction && (previous == null || text(_reason) == null)) {
      throw const MifuException('更正已有记录时，请填写更正原因');
    }
    final Map<String, dynamic> payload;
    if (_kind == 'execution') {
      if (['running', 'paused', 'completed'].contains(_execution) &&
          _started == null) {
        throw const MifuException('此状态需要实际开始时间');
      }
      if (['completed', 'failed', 'cancelled'].contains(_execution) &&
          _ended == null) {
        throw const MifuException('此状态需要实际结束时间');
      }
      if (_started != null && _ended != null && _ended!.isBefore(_started!)) {
        throw const MifuException('结束时间不能早于开始时间');
      }
      final percent = number(_percent);
      if (_execution == 'completed' && percent != null && percent != 100) {
        throw const MifuException('完成进度应留空或填写 100');
      }
      if (_execution == 'queued' &&
          [_duration, _grams, _percent].any((c) => (number(c) ?? 0) != 0)) {
        throw const MifuException('等待打印状态不能填写已发生的时长、用料或进度');
      }
      if (_execution == 'failed' &&
          !['', 'unknown'].contains(_failure) &&
          text(_evidence) == null) {
        throw const MifuException('请补充故障线索；未经核验的原因仍属于人工观察');
      }
      payload = {
        'status': _execution,
        'startedAt': date(_started),
        'endedAt': date(_ended),
        'actualDurationSeconds': number(_duration),
        'materialUsedGrams': number(_grams),
        'completionPercent': percent,
        'failureCategory': _execution == 'failed' && _failure.isNotEmpty
            ? _failure
            : null,
        'failureEvidence': _execution == 'failed' ? text(_evidence) : null,
      };
    } else {
      if (_attempt?['executionEventId'] == null) {
        throw const MifuException('请先保存执行结果，再填写人工质检');
      }
      if (_inspection && _inspected == null) {
        throw const MifuException('请填写实际人工质检时间');
      }
      if (_inspection && _started != null && _inspected!.isBefore(_started!)) {
        throw const MifuException('质检时间不能早于打印开始时间');
      }
      payload = {
        'status': _quality.isEmpty ? null : _quality,
        'inspectedAt': _inspection ? date(_inspected) : null,
        'inspectorId': _inspection
            ? (_newInspection ? _actor : _originalInspectorId ?? _actor)
            : null,
        'qualityScore': _inspection ? number(_score) : null,
        'defectCodes': _inspection ? _defects.toList() : <String>[],
        'notes': text(_notes),
      };
    }
    return {
      'schemaVersion': 1,
      'eventId': const Uuid().v4(),
      'attemptId': _attemptId,
      'recordId': _recordId,
      'plateId': widget.plateId,
      'candidateId': record['candidateId'],
      'eventType': _kind,
      'occurredAt': now.toIso8601String(),
      'source': {
        'kind': 'manual_entry',
        'sourceId': 'desktop-result-form',
        'actorId': _actor,
        'referenceId': null,
      },
      'payload': payload,
      'supersedesEventId': _correction ? previous : null,
      'correctionReason': _correction ? text(_reason) : null,
    };
  }

  Future<void> _save() async {
    if (_loading || _saving || (!_historyFresh && _pending == null)) return;
    if (_pending == null && !(_form.currentState?.validate() ?? false)) return;
    try {
      _pending ??= _buildEvent();
      setState(() {
        _saving = true;
        _error = null;
        _message = null;
      });
      await widget.client.submitOutcome(_pending!);
      if (!mounted) return;
      setState(() {
        _pending = null;
        _correction = false;
        _reason.clear();
        _message = '已保存。实际结果需复核后才能用于训练。';
      });
      await _load(reloadSaved: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A definitive rejection did not append an event. Transport failures
        // retain the exact immutable event for an idempotent retry.
        if (e is MifuException &&
            e.code != null &&
            [400, 401, 403, 404, 409, 413, 422].contains(e.statusCode)) {
          _pending = null;
        }
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_pending != null) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('保存回执尚未确认'),
          content: const Text('建议先重试核对。现在关闭不会自动重发；下次请先查看历史，避免重复补录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回核对'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍然关闭'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _pending = null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final attempt = _attempt;
    final hasPrevious = attempt?['${_kind}EventId'] != null;
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !_saving && _pending == null,
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: Text(
          '打印结果 · ${widget.plateName}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 650,
          height: (size.height * .68).clamp(160.0, 650.0),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Form(
                  key: _form,
                  child: ListView(
                    children: [
                      const Text('执行结果与人工质检分别记录。未测量的项目请留空。'),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (_message != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(_message!),
                        ),
                      if (_pending != null && !_saving)
                        const Text('保存回执尚未确认，请重试核对同一条记录。'),
                      if (!_historyFresh && _pending == null)
                        TextButton(
                          onPressed: () => _load(reloadSaved: true),
                          child: const Text('重新加载'),
                        ),
                      if (_history?.records.isEmpty == true)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('本盘还没有已记录的设备选择。请返回决策中枢，选择设备后点“记录选择”。'),
                        ),
                      if (_record != null) ...[
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: _recordId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '已记录的选择（最近 20 条）',
                          ),
                          items: [
                            for (final r in _history!.records)
                              DropdownMenuItem(
                                value: r['recordId'] as String,
                                child: Text(
                                  '${widget.visiblePrinters[r['candidateId']] ?? '设备'} · ${_dateText(DateTime.tryParse(r['createdAt'] as String))}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _locked
                              ? null
                              : (value) => setState(() {
                                  _recordId = value;
                                  _resetAttempt();
                                  _message = null;
                                }),
                        ),
                        const SizedBox(height: 12),
                        if (_history!.recordsTruncated)
                          const Text('已达本页 20 条选择上限，较早记录可能未显示；本页尚不支持翻页。'),
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'attempt-$_recordId-$_attemptId-${attempt != null}',
                          ),
                          initialValue: attempt == null ? 'new' : _attemptId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '打印批次'),
                          items: [
                            const DropdownMenuItem(
                              value: 'new',
                              child: Text('新增一次打印 / 重打'),
                            ),
                            for (var i = 0; i < _attempts.length; i++)
                              DropdownMenuItem(
                                value: _attempts[i]['attemptId'] as String,
                                child: Text(
                                  '第 ${_attempts.length - i} 次 · ${executionLabels[(_attempts[i]['execution'] as Map?)?['status']] ?? '未记录'} · ${qualityLabels[(_attempts[i]['quality'] as Map?)?['status'] ?? ''] ?? '未填写'}',
                                ),
                              ),
                          ],
                          onChanged: _locked
                              ? null
                              : (value) => setState(() {
                                  _resetAttempt(
                                    _attempts
                                        .where((a) => a['attemptId'] == value)
                                        .firstOrNull,
                                  );
                                  _message = null;
                                }),
                        ),
                        if (_history!.attemptsTruncated)
                          const Text('批次历史超过显示上限，本页仅展示最近部分记录。'),
                        if (attempt != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              attempt['snapshotCapturedAfterStart'] == true
                                  ? '事后采集：原始选择晚于实际开打，不作为事前调度训练样本。'
                                  : attempt['snapshotCapturedAfterStart'] ==
                                        false
                                  ? '记录时间早于开打；来源与结果仍需复核。'
                                  : '采集时序待核验；不会直接作为训练标签。',
                            ),
                          ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: Text(
                                '执行结果',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: _locked
                                          ? null
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                    ),
                              ),
                              selected: _kind == 'execution',
                              onSelected: _locked
                                  ? null
                                  : (_) => setState(() {
                                      _kind = 'execution';
                                      _correction = false;
                                    }),
                            ),
                            ChoiceChip(
                              label: Text(
                                '人工质检',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color:
                                          _locked ||
                                              attempt?['executionEventId'] ==
                                                  null
                                          ? null
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                    ),
                              ),
                              selected: _kind == 'quality',
                              onSelected:
                                  _locked ||
                                      attempt?['executionEventId'] == null
                                  ? null
                                  : (_) => setState(() {
                                      _kind = 'quality';
                                      _correction = false;
                                    }),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_kind == 'execution')
                          ..._executionFields()
                        else
                          ..._qualityFields(),
                        if (hasPrevious &&
                            (_kind != 'quality' || !_newInspection)) ...[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('更正已有记录'),
                            subtitle: const Text('修正填错的内容时打开；历史记录会保留。'),
                            value: _correction,
                            onChanged: _locked
                                ? null
                                : (v) => setState(() => _correction = v),
                          ),
                          if (_correction)
                            TextFormField(
                              controller: _reason,
                              enabled: !_locked,
                              decoration: const InputDecoration(
                                labelText: '更正原因（必填）',
                              ),
                              maxLength: 500,
                            ),
                        ],
                        const SizedBox(height: 12),
                        const Text('这里只保存观察记录，不会开始打印，也不会把“已完成”自动判为合格。'),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _close,
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed:
                _loading ||
                    _saving ||
                    _record == null ||
                    (!_historyFresh && _pending == null)
                ? null
                : _save,
            child: Text(
              _saving
                  ? '保存中'
                  : _pending != null
                  ? '重试保存'
                  : '保存记录',
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _executionFields() => [
    DropdownButtonFormField<String>(
      key: ValueKey('execution-$_attemptId'),
      initialValue: _execution,
      decoration: const InputDecoration(labelText: '实际状态'),
      items: executionLabels.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: _locked ? null : (v) => setState(() => _execution = v!),
    ),
    const SizedBox(height: 10),
    _dateField('开始时间', _started, (v) => _started = v),
    _dateField('结束时间', _ended, (v) => _ended = v),
    _numberField('实际时长（秒）', _duration, 31622400),
    _numberField('实际耗材（克）', _grams, 10000000),
    _numberField('实际进度（%）', _percent, 100),
    if (_execution == 'failed') ...[
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _failure,
        decoration: const InputDecoration(labelText: '疑似原因（可不填，需复核）'),
        items:
            const {
                  '': '未填写',
                  'unknown': '未知',
                  'material': '材料',
                  'operator': '操作',
                  'slicer': '切片',
                  'environment': '环境',
                  'device': '设备',
                  'multiple': '多因素',
                }.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
        onChanged: _locked ? null : (v) => setState(() => _failure = v!),
      ),
      TextFormField(
        controller: _evidence,
        enabled: !_locked,
        maxLines: 2,
        maxLength: 1000,
        decoration: const InputDecoration(labelText: '故障现象 / 判断依据'),
      ),
    ],
  ];

  List<Widget> _qualityFields() => [
    if (_originalInspectorId != null) ...[
      Text(
        _newInspection ? '正在记录一次新的人工检查，请重新填写结果与时间。' : '沿用已有质检归属；修改备注不会更换原质检人。',
      ),
      TextButton(
        onPressed: _locked
            ? null
            : () => setState(() {
                if (_newInspection) {
                  _loadPayload(_attempt);
                } else {
                  _newInspection = true;
                  _correction = false;
                  _reason.clear();
                  _quality = '';
                  _inspected = null;
                  _score.clear();
                  _defects.clear();
                  _notes.clear();
                }
              }),
        child: Text(_newInspection ? '返回原质检记录' : '重新质检'),
      ),
    ],
    DropdownButtonFormField<String>(
      key: ValueKey('quality-$_attemptId-$_newInspection'),
      initialValue: _quality,
      decoration: const InputDecoration(labelText: '人工质检结果'),
      items: qualityLabels.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: _locked ? null : (v) => setState(() => _quality = v!),
    ),
    if (_inspection) ...[
      const SizedBox(height: 10),
      _dateField('质检时间', _inspected, (v) => _inspected = v),
      const Text('此结果由本次操作人手工确认，属于检查观察；完成复核前不作为最终合格标签。'),
      const SizedBox(height: 16),
      _numberField('质量评分（0–100，可不填）', _score, 100),
      const SizedBox(height: 10),
      Wrap(
        spacing: 5,
        children: [
          for (final e in defectLabels.entries)
            FilterChip(
              label: Text(
                e.value,
                style: Theme.of(context).textTheme.labelSmall,
              ),
              selected: _defects.contains(e.key),
              onSelected: _locked
                  ? null
                  : (v) => setState(() {
                      v ? _defects.add(e.key) : _defects.remove(e.key);
                    }),
            ),
        ],
      ),
    ],
    TextFormField(
      controller: _notes,
      enabled: !_locked,
      maxLines: 2,
      maxLength: 1000,
      decoration: const InputDecoration(labelText: '质检备注（可不填）'),
    ),
  ];
}
