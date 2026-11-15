import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/mifu_client.dart';

final mifuClientProvider = Provider.autoDispose<MifuClient>((ref) {
  final client = MifuClient(
    token: Platform.environment['MIFU_API_TOKEN'] ?? '',
  );
  ref.onDispose(client.close);
  return client;
});

/// Poll only while a cluster screen observes the service. No model is started,
/// downloaded or trained as a side effect of opening the desktop application.
final mifuHealthProvider = StreamProvider.autoDispose<MifuHealth>((ref) {
  final client = ref.watch(mifuClientProvider);
  final controller = StreamController<MifuHealth>();
  var busy = false;
  var disposed = false;
  Future<void> refresh() async {
    if (busy || disposed) return;
    busy = true;
    try {
      final health = await client.health();
      if (!disposed) controller.add(health);
    } catch (_) {
      if (!disposed) controller.add(const MifuHealth.disconnected());
    } finally {
      busy = false;
    }
  }

  unawaited(refresh());
  final timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  ref.onDispose(() {
    disposed = true;
    timer.cancel();
    unawaited(controller.close());
  });
  return controller.stream;
});
