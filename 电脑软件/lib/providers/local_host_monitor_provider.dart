import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/local_host_monitor.dart';

final localHostMonitorProvider = Provider.autoDispose<LocalHostMonitor>(
  (_) => LocalHostMonitor(),
);

/// Starts with the observing page and stops when its final listener leaves.
final localHostSnapshotProvider = StreamProvider.autoDispose<LocalHostSnapshot>(
  (ref) {
    final monitor = ref.watch(localHostMonitorProvider);
    final controller = StreamController<LocalHostSnapshot>();
    void sample() => controller.add(monitor.sample());
    sample();
    final timer = Timer.periodic(const Duration(seconds: 3), (_) => sample());
    ref.onDispose(() {
      timer.cancel();
      unawaited(controller.close());
    });
    return controller.stream;
  },
);
