import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One-shot navigation requests used by compact surfaces such as the tray.
final workspaceNavigationRequestProvider =
    StateProvider<String?>((ref) => null);

abstract final class WorkspacePageIds {
  static const dashboard = 'dashboard';
  static const printers = 'printers';
  static const inventory = 'inventory';
  static const cost = 'cost';
  static const restock = 'restock';
  static const statistics = 'statistics';
  static const history = 'history';
  static const projectOrders = 'project_orders';

  /// Personal-workspace name; the legacy route id remains for saved links.
  static const projects = projectOrders;
  static const diagnostics = 'diagnostics';
  static const calibration = 'calibration';
  static const plaza = 'plaza';
  static const firmware = 'firmware';
  static const support = 'support';
  static const settings = 'settings';
  static const studioOverview = 'studio_overview';
  static const studioProduction = 'studio_production';
  static const studioMaterials = 'studio_materials';
  static const studioContinuousPrint = 'studio_continuous_print';
  static const studioAutoEjectGcode = 'studio_auto_eject_gcode';
  static const studioSlicingPresets = 'studio_slicing_presets';
  static const studioInventory = 'studio_inventory';
  static const studioOrders = 'studio_orders';
  static const studioCustomers = 'studio_customers';
  static const studioFinance = 'studio_finance';
  static const studioTeam = 'studio_team';
  static const studioAudit = 'studio_audit';
  static const studioSettings = 'studio_settings';
}
