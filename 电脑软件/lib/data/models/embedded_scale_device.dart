enum EmbeddedScaleTransport { http, websocket, mqtt }

class EmbeddedScaleDevice {
  const EmbeddedScaleDevice({
    required this.deviceId,
    required this.endpoint,
    this.transport = EmbeddedScaleTransport.http,
    this.tareWeightGrams = 0,
    this.stabilitySamples = 3,
    this.stabilityDeltaGrams = 1.0,
    this.readsCuid = true,
    this.readsFuid = true,
  });

  final String deviceId;
  final String endpoint;
  final EmbeddedScaleTransport transport;
  final double tareWeightGrams;
  final int stabilitySamples;
  final double stabilityDeltaGrams;
  final bool readsCuid;
  final bool readsFuid;

  bool get isValid => deviceId.trim().isNotEmpty &&
      Uri.tryParse(endpoint)?.hasScheme == true &&
      tareWeightGrams >= 0 &&
      stabilitySamples >= 2 &&
      stabilityDeltaGrams >= 0;
}
