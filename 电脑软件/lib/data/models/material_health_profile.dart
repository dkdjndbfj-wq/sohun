import '../database/models/consumable_twin_event.dart';

class MaterialHealthProfile {
  const MaterialHealthProfile({
    required this.score,
    required this.rollCount,
    required this.eventCount,
    required this.anomalyCount,
    required this.lastObservedAt,
  });

  final int score;
  final int rollCount;
  final int eventCount;
  final int anomalyCount;
  final DateTime? lastObservedAt;

  String get label => score >= 85 ? '稳定' : score >= 60 ? '需关注' : '风险';

  factory MaterialHealthProfile.fromEvents(
    List<ConsumableTwinEvent> events,
  ) {
    if (events.isEmpty) {
      return const MaterialHealthProfile(
        score: 0,
        rollCount: 0,
        eventCount: 0,
        anomalyCount: 0,
        lastObservedAt: null,
      );
    }
    final rolls = events.map((e) => e.trayUuid).toSet().length;
    final anomalies = events.where((e) =>
        e.eventType == TwinEventType.reconciled ||
        e.eventType == TwinEventType.depleted).length;
    final score = (100 - anomalies * 12).clamp(0, 100);
    return MaterialHealthProfile(
      score: score,
      rollCount: rolls,
      eventCount: events.length,
      anomalyCount: anomalies,
      lastObservedAt: events.map((e) => e.observedAt).reduce(
            (a, b) => a.isAfter(b) ? a : b,
          ),
    );
  }
}
