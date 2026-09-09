/// 响应式断点。配合 LayoutBuilder/Flex 体系适配手机/平板/折叠屏。
class Breakpoints {
  Breakpoints._();

  static const double phone = 600; // < 600 手机
  static const double tablet = 900; // 600~900 小平板
  static const double desktop = 1200; // > 1200 大平板/折叠屏/桌面

  /// 根据宽度判断设备类型
  static WindowSize of(double width) {
    if (width < phone) return WindowSize.phone;
    if (width < tablet) return WindowSize.tablet;
    return WindowSize.desktop;
  }
}

enum WindowSize { phone, tablet, desktop }

extension WindowSizeX on WindowSize {
  bool get isPhone => this == WindowSize.phone;
  bool get isTablet => this == WindowSize.tablet;
  bool get isDesktop => this == WindowSize.desktop;

  /// 列表页网格列数
  int get gridColumns {
    switch (this) {
      case WindowSize.phone:
        return 1;
      case WindowSize.tablet:
        return 2;
      case WindowSize.desktop:
        return 3;
    }
  }

  /// 是否启用双列主从布局（左列表右详情）
  bool get useMasterDetail => this != WindowSize.phone;
}
