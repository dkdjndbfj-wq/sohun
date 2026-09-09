import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

Menu buildAppTrayMenu({
  required String printerLabel,
  required String statusLabel,
  required bool canTogglePrint,
  required bool printPaused,
  required VoidCallback onOpenWorkspace,
  required VoidCallback onOpenInventory,
  required VoidCallback onOpenPrinters,
  required VoidCallback onTogglePrint,
  required VoidCallback onOpenSettings,
  required VoidCallback onExit,
}) {
  return Menu(
    items: [
      MenuItem(
        key: 'printer_status',
        label: printerLabel,
        disabled: true,
      ),
      MenuItem(key: 'print_status', label: statusLabel, disabled: true),
      if (canTogglePrint)
        MenuItem(
          key: 'toggle_print',
          label: printPaused ? '继续打印' : '暂停打印',
          onClick: (_) => onTogglePrint(),
        ),
      MenuItem.separator(),
      MenuItem(
        key: 'open_workspace',
        label: '打开工作台',
        onClick: (_) => onOpenWorkspace(),
      ),
      MenuItem(
        key: 'open_inventory',
        label: '耗材库',
        onClick: (_) => onOpenInventory(),
      ),
      MenuItem(
        key: 'open_printers',
        label: '打印机',
        onClick: (_) => onOpenPrinters(),
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'open_settings',
        label: '设置',
        onClick: (_) => onOpenSettings(),
      ),
      MenuItem(
        key: 'exit_app',
        label: '退出 sohun',
        onClick: (_) => onExit(),
      ),
    ],
  );
}
