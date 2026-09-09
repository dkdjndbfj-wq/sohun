import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/services/app_tray_menu.dart';

void main() {
  test('builds a compact native tray menu with live print actions', () {
    var workspaceCount = 0;
    var inventoryCount = 0;
    var printersCount = 0;
    var toggleCount = 0;
    var settingsCount = 0;
    var exitCount = 0;

    final menu = buildAppTrayMenu(
      printerLabel: 'P1S 工作机',
      statusLabel: '打印中 · 42%',
      canTogglePrint: true,
      printPaused: false,
      onOpenWorkspace: () => workspaceCount++,
      onOpenInventory: () => inventoryCount++,
      onOpenPrinters: () => printersCount++,
      onTogglePrint: () => toggleCount++,
      onOpenSettings: () => settingsCount++,
      onExit: () => exitCount++,
    );

    expect(menu.getMenuItem('printer_status')?.label, 'P1S 工作机');
    expect(menu.getMenuItem('printer_status')?.disabled, isTrue);
    expect(menu.getMenuItem('print_status')?.label, '打印中 · 42%');
    expect(menu.getMenuItem('toggle_print')?.label, '暂停打印');
    expect(menu.getMenuItem('open_workspace')?.label, '打开工作台');
    expect(menu.getMenuItem('open_inventory')?.label, '耗材库');
    expect(menu.getMenuItem('open_printers')?.label, '打印机');
    expect(menu.getMenuItem('open_settings')?.label, '设置');
    expect(menu.getMenuItem('exit_app')?.label, '退出 sohun');

    final workspaceItem = menu.getMenuItem('open_workspace')!;
    final inventoryItem = menu.getMenuItem('open_inventory')!;
    final printersItem = menu.getMenuItem('open_printers')!;
    final toggleItem = menu.getMenuItem('toggle_print')!;
    final settingsItem = menu.getMenuItem('open_settings')!;
    final exitItem = menu.getMenuItem('exit_app')!;

    workspaceItem.onClick!(workspaceItem);
    inventoryItem.onClick!(inventoryItem);
    printersItem.onClick!(printersItem);
    toggleItem.onClick!(toggleItem);
    settingsItem.onClick!(settingsItem);
    exitItem.onClick!(exitItem);

    expect(workspaceCount, 1);
    expect(inventoryCount, 1);
    expect(printersCount, 1);
    expect(toggleCount, 1);
    expect(settingsCount, 1);
    expect(exitCount, 1);
  });

  test('omits print control when the printer is idle', () {
    final menu = buildAppTrayMenu(
      printerLabel: 'A1 mini',
      statusLabel: '已连接 · 待命',
      canTogglePrint: false,
      printPaused: false,
      onOpenWorkspace: () {},
      onOpenInventory: () {},
      onOpenPrinters: () {},
      onTogglePrint: () {},
      onOpenSettings: () {},
      onExit: () {},
    );

    expect(menu.getMenuItem('toggle_print'), isNull);
  });
}
