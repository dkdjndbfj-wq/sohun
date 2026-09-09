/// ESP32 电子秤网关上报的最小数据契约。
///
/// 设备只负责测量和读取标签，库存归属与扣料仍由桌面端确认。
class EmbeddedScaleReading {
  const EmbeddedScaleReading({
    required this.deviceId,
    required this.grossWeightGrams,
    this.tareWeightGrams = 0,
    this.cuid,
    this.fuid,
    required this.measuredAt,
    this.calibrated = false,
  });

  final String deviceId;
  final double grossWeightGrams;
  final double tareWeightGrams;
  final String? cuid;
  final String? fuid;
  final DateTime measuredAt;
  final bool calibrated;

  bool get hasTag => (cuid?.trim().isNotEmpty ?? false) ||
      (fuid?.trim().isNotEmpty ?? false);

  double get netWeightGrams =>
      (grossWeightGrams - tareWeightGrams).clamp(0.0, double.infinity);

  factory EmbeddedScaleReading.fromJson(Map<String, Object?> json) {
    final deviceId = (json['device_id'] ?? json['deviceId'])?.toString().trim() ?? '';
    final rawWeight = json['gross_weight_g'] ?? json['weight_g'] ?? json['weightGrams'];
    final weight = rawWeight is num ? rawWeight.toDouble() : double.tryParse('$rawWeight');
    final rawTare = json['tare_weight_g'] ??
        json['tareWeightGrams'] ??
        _knownTareWeights[json['spool_type']?.toString().toLowerCase()];
    final tare = rawTare is num ? rawTare.toDouble() : double.tryParse('$rawTare');
    final timestamp = json['measured_at'] ?? json['measuredAt'];
    final measuredAt = timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt(), isUtc: true)
        : DateTime.tryParse('$timestamp')?.toUtc();
    if (deviceId.isEmpty || weight == null || !weight.isFinite || weight < 0 || tare == null || !tare.isFinite || tare < 0 || measuredAt == null) {
      throw const FormatException('ESP32 电子秤数据无效');
    }
    return EmbeddedScaleReading(
      deviceId: deviceId,
      grossWeightGrams: weight,
      tareWeightGrams: tare,
      cuid: json['cuid']?.toString(),
      fuid: json['fuid']?.toString(),
      measuredAt: measuredAt,
      calibrated: json['calibrated'] == true,
    );
  }
}

/// 常见料盘壳的参考皮重，仅用于设备未上报 tare_weight_g 时的临时估算；
/// 正式入库建议由 ESP32 校准后直接上报皮重。
const Map<String, double> _knownTareWeights = {
  'bambu_ams': 250,
  'standard_1kg': 230,
};
