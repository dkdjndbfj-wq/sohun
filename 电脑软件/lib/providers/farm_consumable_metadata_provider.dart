import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/database.dart';
import 'database_provider.dart';
import 'studio_provider.dart';

final farmConsumableMetadataProvider =
    FutureProvider<Map<int, FarmConsumableMetadata>>((ref) async {
  final studioState = ref.watch(studioSnapshotProvider);
  final inventoryState = ref.watch(farmConsumablesProvider);
  final studio = studioState.valueOrNull;
  final inventory = inventoryState.valueOrNull;
  if (studio == null || inventory == null) return const {};
  return ref.read(consumableDaoProvider).getFarmConsumableMetadata(
        inventory.map((item) => item.id),
        workspaceId: studio.workspace.id,
      );
});
