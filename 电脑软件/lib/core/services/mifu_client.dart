import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Local, advisory-only Mifu protocol. This client has no printer operations.
class MifuClient {
  MifuClient({http.Client? client, Uri? endpoint, this.token = ''})
    : _client = client ?? http.Client(),
      endpoint = endpoint ?? Uri.parse('http://127.0.0.1:27961') {
    if (this.endpoint.scheme != 'http' ||
        this.endpoint.host != '127.0.0.1' ||
        this.endpoint.userInfo.isNotEmpty ||
        this.endpoint.hasQuery ||
        this.endpoint.hasFragment ||
        !['', '/'].contains(this.endpoint.path)) {
      throw ArgumentError('Mifu 只允许连接本机 127.0.0.1');
    }
  }

  final http.Client _client;
  final Uri endpoint;
  final String token;

  void close() => _client.close();

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final abort = Completer<void>();
    Future<Map<String, dynamic>> execute() async {
      final request =
          http.AbortableRequest(
              body == null ? 'GET' : 'POST',
              endpoint.resolve(path),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers['Accept'] = 'application/json';
      if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final response = await _client.send(request);
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const MifuException('模型响应过大');
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const MifuException('模型响应格式不正确');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error'];
        final message = error is Map ? error['message'] : null;
        throw MifuException(
          message is String ? message : 'Mifu 暂不可用',
          statusCode: response.statusCode,
          code: error is Map && error['code'] is String
              ? error['code'] as String
              : null,
        );
      }
      return decoded;
    }

    try {
      return await execute().timeout(timeout);
    } on MifuException {
      rethrow;
    } on TimeoutException {
      throw const MifuException('Mifu 响应超时，请稍后重试');
    } on FormatException {
      throw const MifuException('模型响应格式不正确');
    } catch (_) {
      throw const MifuException('未连接本机 Mifu 服务');
    } finally {
      // Future.timeout alone leaves the underlying socket/response stream alive.
      // Release it before health polling or an explicit retry starts a new call.
      abort.complete();
    }
  }

  Future<MifuHealth> health() async =>
      MifuHealth.fromJson(await _request('/health'));

  Future<MifuDecision> decide(MifuDecisionRequest request) async {
    request.validate();
    final data = await _request(
      '/v1/decisions',
      body: request.toJson(),
      timeout: const Duration(seconds: 45),
    );
    return MifuDecision.fromJson(data, request: request);
  }

  Future<MifuInputCheck> checkDecision(MifuDecisionRequest request) async {
    request.validate();
    if (request.inputContract != 'mifu-decision-v4') {
      throw const MifuException('条件检查需要新版决策输入');
    }
    final data = await _request('/v1/decisions/check', body: request.toJson());
    return MifuInputCheck.fromJson(data, request);
  }

  /// Human feedback is an observation, not an optimality label or a print command.
  Future<String> record({
    required MifuDecisionRequest request,
    required String selectedCandidateId,
    MifuDecision? decision,
  }) async {
    request.validate(allowSingleCandidate: true);
    if (request.candidates.length == 1 && decision != null) {
      throw const MifuException('单设备选择只能记录人工观察，不能附加模型排名');
    }
    if (!request.candidateIds.contains(selectedCandidateId)) {
      throw const MifuException('所选设备不属于本次候选');
    }
    final data = await _request(
      '/v1/records',
      body: {
        'request': request.toJson(),
        'decision': decision?.raw,
        'feedback': decision == null
            ? 'observed'
            : decision.choice == selectedCandidateId
            ? 'accepted'
            : 'corrected',
        'selectedCandidateId': selectedCandidateId,
        if (request.observation != null) 'observation': request.observation,
      },
    );
    if (data['recordId'] is! String || data['trainingEligible'] != false) {
      throw const MifuException('反馈保存结果不正确');
    }
    return data['recordId'] as String;
  }

  Future<MifuRecordHistory> queryRecords({
    required String plateId,
    required Set<String> candidateIds,
  }) async {
    if (plateId.isEmpty ||
        candidateIds.isEmpty ||
        candidateIds.any((id) => id.isEmpty)) {
      throw const MifuException('结果查询需要有效打印盘及当前可见设备');
    }
    // Freeze the caller's scope across asynchronous reads. Each server request
    // stays bounded without dropping printers beyond the first 64.
    final ids = candidateIds.toList(growable: false);
    final records = <String, Map<String, dynamic>>{};
    final attempts = <String, Map<String, dynamic>>{};
    var attemptsTruncated = false;
    var recordsTruncated = false;
    for (var start = 0; start < ids.length; start += 64) {
      final end = start + 64 < ids.length ? start + 64 : ids.length;
      final chunk = ids.sublist(start, end).toSet();
      final data = await _request(
        '/v1/records/query',
        body: {'plateId': plateId, 'candidateIds': chunk.toList()},
      );
      final history = MifuRecordHistory.fromJson(data, plateId, chunk);
      attemptsTruncated |= history.attemptsTruncated;
      recordsTruncated |= history.recordsTruncated;
      for (final record in history.records) {
        final id = record['recordId'] as String;
        if (records.containsKey(id) &&
            jsonEncode(records[id]) != jsonEncode(record)) {
          throw const MifuException('选择历史在查询期间发生冲突，请重新加载');
        }
        records[id] = record;
      }
      for (final attempt in history.attempts) {
        final id = attempt['attemptId'] as String;
        if (attempts.containsKey(id) &&
            jsonEncode(attempts[id]) != jsonEncode(attempt)) {
          throw const MifuException('打印批次在查询期间发生冲突，请重新加载');
        }
        attempts[id] = attempt;
      }
    }
    int recent(
      Map<String, dynamic> a,
      Map<String, dynamic> b,
      String time,
      String id,
    ) {
      final first = DateTime.tryParse(a[time] as String? ?? '');
      final second = DateTime.tryParse(b[time] as String? ?? '');
      if (first == null || second == null) {
        throw const MifuException('历史记录缺少有效时间，请核对本机记录');
      }
      final byTime = second.compareTo(first);
      return byTime == 0
          ? (b[id] as String).compareTo(a[id] as String)
          : byTime;
    }

    final orderedRecords = records.values.toList()
      ..sort((a, b) => recent(a, b, 'createdAt', 'recordId'));
    final visibleRecords = orderedRecords.take(20).toList();
    final recordIds = visibleRecords.map((r) => r['recordId']).toSet();
    final orderedAttempts =
        attempts.values.where((a) => recordIds.contains(a['recordId'])).toList()
          ..sort((a, b) => recent(a, b, 'lastOccurredAt', 'attemptId'));
    return MifuRecordHistory(
      List.unmodifiable(visibleRecords),
      List.unmodifiable(orderedAttempts.take(100)),
      attemptsTruncated || orderedAttempts.length > 100,
      recordsTruncated: recordsTruncated || orderedRecords.length > 20,
    );
  }

  /// The caller retains this exact event until acknowledgment, including its ID.
  Future<void> submitOutcome(Map<String, dynamic> event) async {
    final data = await _request('/v1/outcomes', body: event);
    if (data['eventId'] != event['eventId'] ||
        data['attemptId'] != event['attemptId'] ||
        data['recordId'] != event['recordId'] ||
        data['trainingEligible'] != false ||
        data['duplicate'] is! bool) {
      throw const MifuException('结果保存回执不一致，请重试核对');
    }
  }
}

class MifuException implements Exception {
  const MifuException(this.message, {this.code, this.statusCode});
  final String message;
  final String? code;
  final int? statusCode;
  @override
  String toString() => message;
}

class MifuRecordHistory {
  const MifuRecordHistory(
    this.records,
    this.attempts,
    this.attemptsTruncated, {
    this.recordsTruncated = false,
  });
  final List<Map<String, dynamic>> records, attempts;
  final bool attemptsTruncated;

  /// A full server page may hide older rows until cursor pagination exists.
  final bool recordsTruncated;

  static bool _identifier(Object? value) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= 128 &&
      !RegExp(r'[\x00-\x1f]').hasMatch(value);

  static bool _text(Object? value) =>
      value == null ||
      (value is String &&
          value.trim().isNotEmpty &&
          value.length <= 2000 &&
          !RegExp(r'[\x00-\x08\x0b-\x1f]').hasMatch(value));

  static bool _number(Object? value, num maximum) =>
      value == null ||
      (value is num && value.isFinite && value >= 0 && value <= maximum);

  static bool _timestamp(Object? value, {bool nullable = false}) {
    if (value == null) return nullable;
    if (value is! String || value.length > 40) return false;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))$',
    ).firstMatch(value);
    if (match == null) return false;
    int part(int index) => int.parse(match.group(index) ?? '0');
    final year = part(1), month = part(2), day = part(3);
    // DateTime.tryParse normalizes impossible dates (for example February 30).
    // Check calendar fields as well as the explicit offset before using them.
    if (year < 1 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > DateTime.utc(year, month + 1, 0).day ||
        part(4) > 23 ||
        part(5) > 59 ||
        part(6) > 59 ||
        part(7) > 23 ||
        part(8) > 59) {
      return false;
    }
    return DateTime.tryParse(value) != null;
  }

  static bool _validPayload(String kind, Map<String, dynamic> payload) {
    if (kind == 'execution') {
      return payload.keys.toSet().containsAll({
            'status',
            'startedAt',
            'endedAt',
            'actualDurationSeconds',
            'materialUsedGrams',
            'completionPercent',
            'failureCategory',
            'failureEvidence',
          }) &&
          const {
            'unknown',
            'queued',
            'running',
            'paused',
            'completed',
            'failed',
            'cancelled',
          }.contains(payload['status']) &&
          _timestamp(payload['startedAt'], nullable: true) &&
          _timestamp(payload['endedAt'], nullable: true) &&
          _number(payload['actualDurationSeconds'], 31622400) &&
          _number(payload['materialUsedGrams'], 10000000) &&
          _number(payload['completionPercent'], 100) &&
          const {
            null,
            'unknown',
            'material',
            'operator',
            'slicer',
            'environment',
            'device',
            'multiple',
          }.contains(payload['failureCategory']) &&
          _text(payload['failureEvidence']);
    }
    final defects = payload['defectCodes'];
    return payload.keys.toSet().containsAll({
          'status',
          'inspectedAt',
          'inspectorId',
          'qualityScore',
          'defectCodes',
          'notes',
        }) &&
        const {
          null,
          'not_inspected',
          'unknown',
          'pass',
          'rework',
          'reject',
        }.contains(payload['status']) &&
        _timestamp(payload['inspectedAt'], nullable: true) &&
        (payload['inspectorId'] == null ||
            _identifier(payload['inspectorId'])) &&
        _number(payload['qualityScore'], 100) &&
        defects is List &&
        defects.length <= 16 &&
        defects.toSet().length == defects.length &&
        defects.every(
          const {
            'warping',
            'stringing',
            'layer_shift',
            'under_extrusion',
            'dimensions',
            'surface',
            'missing_part',
            'support',
            'adhesion',
            'other',
          }.contains,
        ) &&
        _text(payload['notes']);
  }

  factory MifuRecordHistory.fromJson(
    Map<String, dynamic> data,
    String plateId,
    Set<String> candidateIds,
  ) {
    final records = data['records'];
    final attempts = data['attempts'];
    if (data['trainingEligible'] != false ||
        records is! List ||
        attempts is! List ||
        records.length > 20 ||
        attempts.length > 100 ||
        data['attemptsTruncated'] is! bool ||
        (data['recordsTruncated'] != null &&
            data['recordsTruncated'] is! bool)) {
      throw const MifuException('结果历史格式不正确');
    }
    final byId = <String, Map<String, dynamic>>{};
    for (final record in records) {
      if (record is! Map<String, dynamic> ||
          !_identifier(record['recordId']) ||
          record['plateId'] != plateId ||
          !candidateIds.contains(record['candidateId']) ||
          byId.containsKey(record['recordId'])) {
        throw const MifuException('结果历史超出本次设备或打印盘范围');
      }
      if (!_timestamp(record['createdAt'])) {
        throw const MifuException('历史记录缺少有效时间，请核对本机记录');
      }
      byId[record['recordId'] as String] = Map.unmodifiable(record);
    }
    final attemptIds = <String>{};
    final checkedAttempts = <Map<String, dynamic>>[];
    for (final attempt in attempts) {
      if (attempt is! Map<String, dynamic> ||
          !_identifier(attempt['attemptId']) ||
          !attemptIds.add(attempt['attemptId'] as String) ||
          !byId.containsKey(attempt['recordId']) ||
          attempt['plateId'] != plateId ||
          attempt['candidateId'] != byId[attempt['recordId']]!['candidateId'] ||
          ![null, false].contains(attempt['trainingEligible'])) {
        throw const MifuException('打印批次与原始选择不一致');
      }
      if (!_timestamp(attempt['lastOccurredAt']) ||
          ![
            null,
            true,
            false,
          ].contains(attempt['snapshotCapturedAfterStart'])) {
        throw const MifuException('打印批次时间格式不正确');
      }
      for (final kind in ['execution', 'quality']) {
        final payload = attempt[kind];
        final eventId = attempt['${kind}EventId'];
        if ((payload == null) != (eventId == null) ||
            (payload != null &&
                (payload is! Map<String, dynamic> ||
                    !_identifier(eventId) ||
                    !_validPayload(kind, payload)))) {
          throw const MifuException('打印批次记录不完整');
        }
      }
      checkedAttempts.add(Map.unmodifiable(attempt));
    }
    return MifuRecordHistory(
      List.unmodifiable(byId.values),
      List.unmodifiable(checkedAttempts),
      data['attemptsTruncated'] as bool,
      recordsTruncated:
          data['recordsTruncated'] == true || records.length >= 20,
    );
  }
}

class MifuDecisionRequest {
  const MifuDecisionRequest({
    required this.requestId,
    required this.plate,
    required this.candidates,
    this.observation,
    this.decisionContext,
  });
  final String requestId;
  final Map<String, dynamic> plate;
  final List<Map<String, dynamic>> candidates;

  /// Recorded with the selection, never added to the encoder's input.
  final Map<String, Object?>? observation;
  final Map<String, dynamic>? decisionContext;
  String get inputContract =>
      decisionContext?['schema'] as String? ?? 'legacy_v1';
  Set<String> get candidateIds =>
      candidates.map((c) => c['id']).whereType<String>().toSet();
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'plate': plate,
    'candidates': candidates,
    if (decisionContext != null) 'decision_context': decisionContext,
  };
  void validate({bool allowSingleCandidate = false}) {
    if (requestId.isEmpty ||
        plate['id'] is! String ||
        candidates.length < (allowSingleCandidate ? 1 : 2) ||
        candidates.length > 16 ||
        candidateIds.length != candidates.length ||
        candidateIds.any((id) => id.isEmpty) ||
        candidates.any((c) => c['features'] is! Map)) {
      throw MifuException(
        '需要 ${allowSingleCandidate ? '1' : '2'}–16 台唯一候选设备及有效打印盘',
      );
    }
    if (decisionContext != null &&
        (decisionContext!['schema'] != 'mifu-decision-v4' ||
            decisionContext!['source'] != 'live_snapshot' ||
            candidates.any((c) => c['admission'] is! Map))) {
      throw const MifuException('新版决策缺少本次设备检查记录');
    }
  }
}

class MifuInputCheck {
  const MifuInputCheck({
    required this.evidencePassed,
    required this.tokenAuditStatus,
    required this.modelReady,
    required this.canInfer,
    required this.issues,
  });
  final bool evidencePassed, modelReady, canInfer;
  final String tokenAuditStatus;
  final List<String> issues;

  factory MifuInputCheck.fromJson(
    Map<String, dynamic> data,
    MifuDecisionRequest request,
  ) {
    final audit = data['tokenAudit'];
    final issues = data['issues'];
    if (data['requestId'] != request.requestId ||
        data['inputContract'] != request.inputContract ||
        !['passed', 'blocked'].contains(data['evidenceStatus']) ||
        audit is! Map ||
        !['pending', 'passed', 'failed'].contains(audit['status']) ||
        data['modelReady'] is! bool ||
        data['canInfer'] is! bool ||
        data['advisoryOnly'] != true ||
        data['automaticExecutionAuthorized'] != false ||
        issues is! List ||
        issues.length > 64 ||
        issues.any(
          (issue) =>
              issue is! Map ||
              issue['message'] is! String ||
              (issue['message'] as String).isEmpty,
        )) {
      throw const MifuException('条件检查回执与本次打印盘不一致');
    }
    final passed = data['evidenceStatus'] == 'passed';
    if (data['canInfer'] == true &&
        (!passed ||
            data['modelReady'] != true ||
            audit['status'] != 'passed' ||
            issues.isNotEmpty)) {
      throw const MifuException('条件检查状态相互矛盾，请重新检查');
    }
    return MifuInputCheck(
      evidencePassed: passed,
      tokenAuditStatus: audit['status'] as String,
      modelReady: data['modelReady'] as bool,
      canInfer: data['canInfer'] as bool,
      issues: List.unmodifiable(
        issues.map((issue) => (issue as Map)['message'] as String),
      ),
    );
  }
}

class MifuHealth {
  const MifuHealth({
    required this.trainingState,
    this.version,
    this.device,
    this.gpuName,
    this.utilizationPercent,
    this.memoryUsedMb,
    this.memoryTotalMb,
    this.temperatureC,
    this.inputContract,
    this.supportedObjectives = const [],
    this.supportedInputContracts = const [],
  });
  const MifuHealth.disconnected() : this(trainingState: 'disconnected');
  final String trainingState;
  final String? version, device, gpuName;
  final String? inputContract;
  final List<String> supportedObjectives, supportedInputContracts;
  bool get supportsV4Check =>
      supportedInputContracts.contains('mifu-decision-v4');
  final double? utilizationPercent, memoryUsedMb, memoryTotalMb, temperatureC;
  bool get ready => trainingState == 'ready';
  String get label => switch (trainingState) {
    'ready' => '已连接',
    'unconfigured' => '待训练',
    'loading' => '加载中',
    'error' => '加载失败',
    _ => '待连接',
  };

  factory MifuHealth.fromJson(Map<String, dynamic> data) {
    if (data['service'] != 'mifu' ||
        data['apiVersion'] != 1 ||
        data['status'] != 'ok') {
      throw const MifuException('本机服务不是兼容的 Mifu 服务');
    }
    final state = data['trainingState'];
    if (!['ready', 'unconfigured', 'loading', 'error'].contains(state)) {
      throw const MifuException('未知的 Mifu 状态');
    }
    final model = data['model'];
    if (model is! Map || model['name'] != 'Mifu') {
      throw const MifuException('模型身份不正确');
    }
    final version = model['version'];
    if (state == 'ready' &&
        (model['checkpointConfigured'] != true ||
            version is! String ||
            version.trim().isEmpty)) {
      throw const MifuException('Mifu 尚未配置专属权重');
    }
    final host = data['host'];
    double? metric(String key) {
      final value = host is Map ? host[key] : null;
      return value is num && value.isFinite && value >= 0
          ? value.toDouble()
          : null;
    }

    return MifuHealth(
      trainingState: state as String,
      version: version is String ? version : null,
      device: model['device'] is String ? model['device'] as String : null,
      gpuName: host is Map && host['gpuName'] is String
          ? host['gpuName'] as String
          : null,
      utilizationPercent: metric('utilizationPercent'),
      memoryUsedMb: metric('memoryUsedMb'),
      memoryTotalMb: metric('memoryTotalMb'),
      temperatureC: metric('temperatureC'),
      inputContract: model['inputContract'] is String
          ? model['inputContract'] as String
          : null,
      supportedObjectives: model['supportedObjectives'] is List
          ? List.unmodifiable(
              (model['supportedObjectives'] as List).whereType<String>(),
            )
          : const [],
      supportedInputContracts: data['supportedInputContracts'] is List
          ? List.unmodifiable(
              (data['supportedInputContracts'] as List).whereType<String>(),
            )
          : const [],
    );
  }
}

class MifuDecision {
  const MifuDecision({
    required this.choice,
    required this.probabilities,
    required this.elapsedMs,
    required this.version,
    required this.raw,
  });
  final String choice;
  final Map<String, double> probabilities;
  final double elapsedMs;
  final String version;
  final Map<String, dynamic> raw;

  factory MifuDecision.fromJson(
    Map<String, dynamic> data, {
    required MifuDecisionRequest request,
  }) {
    final probabilities = data['probabilities'];
    final model = data['model'];
    final elapsed = data['elapsedMs'];
    final choice = data['choice'];
    if (request.inputContract == 'mifu-decision-v4' &&
        (data['inputContract'] != request.inputContract ||
            model is! Map ||
            model['inputContract'] != request.inputContract)) {
      throw const MifuException('模型输入版本不一致，请刷新模型状态');
    }
    if (data['requestId'] != request.requestId ||
        data['trainingState'] != 'ready' ||
        choice is! String ||
        !request.candidateIds.contains(choice) ||
        model is! Map ||
        model['name'] != 'Mifu' ||
        model['checkpointConfigured'] != true ||
        model['version'] is! String ||
        (model['version'] as String).trim().isEmpty ||
        elapsed is! num ||
        !elapsed.isFinite ||
        elapsed < 0 ||
        probabilities is! Map ||
        probabilities.length != request.candidateIds.length) {
      throw const MifuException('模型结果与本次候选不一致');
    }
    final values = <String, double>{};
    for (final id in request.candidateIds) {
      final probability = probabilities[id];
      if (probability is! num ||
          !probability.isFinite ||
          probability < 0 ||
          probability > 1) {
        throw const MifuException('模型返回了无效概率');
      }
      values[id] = probability.toDouble();
    }
    if ((values.values.fold<double>(0, (a, b) => a + b) - 1).abs() > .001) {
      throw const MifuException('模型概率分布不完整');
    }
    if (values.values.any((value) => value > values[choice]! + .0001)) {
      throw const MifuException('模型选择与概率不一致');
    }
    return MifuDecision(
      choice: choice,
      probabilities: Map.unmodifiable(values),
      elapsedMs: elapsed.toDouble(),
      version: model['version'] as String,
      raw: Map.unmodifiable(data),
    );
  }
}
