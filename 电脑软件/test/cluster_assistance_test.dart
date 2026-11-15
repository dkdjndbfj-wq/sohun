import 'package:consumable_tracker_desktop/features/cluster/cluster_assistance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final observed = DateTime.utc(2026, 11, 15, 10);
  test(
    'preparation reuses original observation and preserves unknown values',
    () {
      final cache = ClusterPreparationCache();
      cache.store(
        fingerprint: 'facts',
        modelIdentity: 'model',
        candidateIds: [1, 2],
        values: {1: 0},
        observedAt: observed,
      );
      final reused = cache.read(
        fingerprint: 'facts',
        modelIdentity: 'model',
        candidateIds: [2, 1],
        now: observed.add(const Duration(seconds: 30)),
      )!;
      expect(reused.values, {1: 0, 2: null});
      expect(reused.observedAt, observed);
      expect(() => reused.values[1] = 10, throwsUnsupportedError);
      expect(
        cache.read(
          fingerprint: 'facts',
          modelIdentity: 'model',
          candidateIds: [1, 2],
          now: observed.add(const Duration(seconds: 120)),
        ),
        isNull,
      );
    },
  );
  for (final change in ['facts', 'model', 'candidate', 'clock']) {
    test('$change change permanently invalidates cached preparation', () {
      final cache = ClusterPreparationCache();
      cache.store(
        fingerprint: 'facts',
        modelIdentity: 'model',
        candidateIds: [1, 2],
        values: {1: 30, 2: 90},
        observedAt: observed,
      );
      expect(
        cache.read(
          fingerprint: change == 'facts' ? 'other' : 'facts',
          modelIdentity: change == 'model' ? 'other' : 'model',
          candidateIds: change == 'candidate' ? [1] : [1, 2],
          now: change == 'clock'
              ? observed.subtract(const Duration(seconds: 1))
              : observed,
        ),
        isNull,
      );
      expect(
        cache.read(
          fingerprint: 'facts',
          modelIdentity: 'model',
          candidateIds: [1, 2],
          now: observed,
        ),
        isNull,
      );
    });
  }
}
