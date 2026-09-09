import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/daos/printer_dao.dart';
import '../data/seed/printer_seed.dart';
import 'database_provider.dart';

/// 打印机列表（含通道与绑定的耗材，实时流）。三表 merge 触发，任一变化自动刷新。
final printersWithChannelsProvider =
    StreamProvider<List<PrinterWithChannels>>((ref) {
  return ref.watch(printerDaoProvider).watchAllWithChannels();
});

/// Visual facts used by a printer card on the dashboard.
///
/// Remaining grams are deliberately excluded. Real-time consumption writes to
/// the consumables table every few seconds, but the printer card only displays
/// whether a channel is active. Excluding the exact gram value prevents those
/// background writes from rebuilding the whole master/detail area.
class DashboardPrinterSummary {
  const DashboardPrinterSummary({
    required this.id,
    required this.name,
    required this.brand,
    required this.model,
    required this.channelCount,
    required this.imageAsset,
    required this.isCustomImage,
    required this.serial,
    required this.activeChannelCount,
  });

  factory DashboardPrinterSummary.from(PrinterWithChannels data) {
    final printer = data.printer;
    return DashboardPrinterSummary(
      id: printer.id,
      name: printer.name,
      brand: printer.brand,
      model: printer.model,
      channelCount: printer.channelCount,
      imageAsset: printer.imageAsset,
      isCustomImage: printer.isCustomImage,
      serial: data.serial,
      activeChannelCount: data.channels.where((item) => item.isActive).length,
    );
  }

  final int id;
  final String? name;
  final String brand;
  final String model;
  final int channelCount;
  final String? imageAsset;
  final bool isCustomImage;
  final String? serial;
  final int activeChannelCount;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DashboardPrinterSummary &&
            id == other.id &&
            name == other.name &&
            brand == other.brand &&
            model == other.model &&
            channelCount == other.channelCount &&
            imageAsset == other.imageAsset &&
            isCustomImage == other.isCustomImage &&
            serial == other.serial &&
            activeChannelCount == other.activeChannelCount;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        brand,
        model,
        channelCount,
        imageAsset,
        isCustomImage,
        serial,
        activeChannelCount,
      );
}

enum DashboardPrinterListPhase { loading, data, error }

/// Stable dashboard projection of [printersWithChannelsProvider].
class DashboardPrinterListState {
  const DashboardPrinterListState._({
    required this.phase,
    this.printers = const [],
    this.error,
  });

  const DashboardPrinterListState.loading()
      : this._(phase: DashboardPrinterListPhase.loading);

  const DashboardPrinterListState.data(
    List<DashboardPrinterSummary> printers,
  ) : this._(
          phase: DashboardPrinterListPhase.data,
          printers: printers,
        );

  DashboardPrinterListState.error(Object error)
      : this._(
          phase: DashboardPrinterListPhase.error,
          error: error,
        );

  final DashboardPrinterListPhase phase;
  final List<DashboardPrinterSummary> printers;
  final Object? error;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DashboardPrinterListState ||
        phase != other.phase ||
        error?.toString() != other.error?.toString() ||
        printers.length != other.printers.length) {
      return false;
    }
    for (var i = 0; i < printers.length; i++) {
      if (printers[i] != other.printers[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        phase,
        error?.toString(),
        Object.hashAll(printers),
      );
}

final dashboardPrinterListProvider = Provider<DashboardPrinterListState>((ref) {
  final async = ref.watch(printersWithChannelsProvider);
  return async.when(
    skipLoadingOnReload: true,
    skipLoadingOnRefresh: true,
    loading: () => const DashboardPrinterListState.loading(),
    error: (error, _) => DashboardPrinterListState.error(error),
    data: (printers) => DashboardPrinterListState.data(
      printers.map(DashboardPrinterSummary.from).toList(growable: false),
    ),
  );
});

/// 单台打印机详情流。autoDispose 避免浏览多台打印机后 Stream 泄漏。
final printerDetailProvider =
    StreamProvider.autoDispose.family<PrinterWithChannels?, int>((ref, id) {
  return ref.watch(printerDaoProvider).watchByIdWithChannels(id);
});

/// 打印机预设清单（按品牌分组），供「添加打印机」选择。
final printerPresetsProvider =
    Provider<Map<String, List<PrinterPreset>>>((ref) {
  return PrinterPresets.groupedByBrand();
});
