import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/printer_fleet_connection_manager.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../studio/farm_printer_camera_dialog.dart';
import '../../providers/printer_connection_provider.dart';

/// Opens the camera that belongs to the selected personal-edition printer.
///
/// The effective config comes from [mergedPrinterListProvider], so a printer
/// explicitly set to cloud mode never falls back to its LAN credentials.
Future<void> showPrinterCameraDialog(
  BuildContext context,
  WidgetRef ref, {
  required PrinterWithChannels printer,
}) async {
  final serial = printer.serial?.trim();
  PrinterConnectionConfig? config;
  if (serial != null && serial.isNotEmpty) {
    for (final candidate in ref.read(mergedPrinterListProvider)) {
      if (candidate.serial == serial) {
        config = candidate;
        break;
      }
    }
  }

  FleetPrinterState? state;
  if (serial != null && serial.isNotEmpty) {
    for (final candidate in ref.read(fleetPrinterStatesProvider)) {
      if (candidate.serial == serial) {
        state = candidate;
        break;
      }
    }
  }

  final printerName = printer.printer.name?.trim().isNotEmpty == true
      ? printer.printer.name!.trim()
      : printer.printer.model;
  final model = config?.devProductName?.trim().isNotEmpty == true
      ? config!.devProductName!.trim()
      : state?.reportedModel?.trim().isNotEmpty == true
          ? state!.reportedModel!.trim()
          : printer.printer.model;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => FarmPrinterCameraDialog(
      printerName: printerName,
      serial: serial,
      model: model,
      config: config,
      compact: true,
    ),
  );
}
