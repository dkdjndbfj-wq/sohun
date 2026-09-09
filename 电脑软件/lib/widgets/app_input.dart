import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';

/// 苹果风格输入框，带聚焦光环 + 搜索框变体。
///
/// 聚焦态：1.5px primary 描边 + 外层 3px primary 15% 光环（Container 嵌套 + AnimatedContainer 切换）。
/// 非聚焦：1px outline 描边 + surfaceContainerHigh 填充。
/// 错误态：红色描边 + 红色 helperText。
/// search 变体：圆角胶囊 + 搜索图标前缀 + 更大 padding。
class AppInput extends StatefulWidget {
  /// 标签文字（位于输入框上方），可选。
  final String? label;

  /// 占位提示文字。
  final String? hint;

  /// 文本控制器。
  final TextEditingController? controller;

  /// 是否使用搜索框变体（圆角胶囊 + 搜索图标前缀 + 更大 padding）。
  final bool search;

  /// 错误文案；非空时显示红色描边 + 红色 helperText。
  final String? errorText;

  /// 是否隐藏文本（密码输入）。
  final bool obscureText;

  /// 键盘类型。
  final TextInputType? keyboardType;

  /// 自定义前缀图标（位于输入框内部左侧）。
  /// search 变体下若未提供，自动使用 Icons.search_rounded。
  final Widget? prefixIcon;

  /// 自定义后缀图标。
  final Widget? suffixIcon;

  /// 文本变化回调。
  final ValueChanged<String>? onChanged;

  /// 提交回调（回车）。
  final ValueChanged<String>? onSubmitted;

  /// 输入格式化器（如数字过滤）。
  final List<TextInputFormatter>? inputFormatters;

  const AppInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.search = false,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
  });

  @override
  State<AppInput> createState() => _AppInputState();
}

class _AppInputState extends State<AppInput> {
  late final FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _focused) {
      setState(() => _focused = focused);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    // 填充 / 描边 / 文字 颜色解析
    final personal = PersonalDesktopTheme.of(context);
    final Color fill = personal != null
        ? personalDesktopGlassFill(Theme.of(context))
        : isDark
        ? AppColors.surfaceContainerHighDark
        : AppColors.surfaceContainerHigh;
    final Color outlineBase = personal != null
        ? personalDesktopGlassRim(Theme.of(context))
        : (isDark ? AppColors.outlineDark : AppColors.outline);
    final Color textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final Color hintColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    // 描边色 + 宽度
    final Color borderColor;
    if (hasError) {
      borderColor = AppColors.danger;
    } else if (_focused) {
      borderColor = AppColors.primary;
    } else {
      borderColor = outlineBase;
    }
    final double borderWidth = (_focused || hasError) ? 1.5 : 1.0;

    // 外层光环色（聚焦时显示 3px 15% primary）
    final Color ringColor = hasError
        ? AppColors.danger.withValues(alpha: 0.15)
        : AppColors.primary.withValues(alpha: 0.15);

    final bool isSearch = widget.search;
    final double innerRadius = isSearch && personal == null
        ? AppColors.radiusFull
        : AppColors.radiusMd;
    final double outerRadius = innerRadius + 3; // 外环留出 3px 边框宽度

    // contentPadding：search 变体更大
    final EdgeInsets contentPadding = isSearch
        ? const EdgeInsets.symmetric(horizontal: 18, vertical: 16)
        : const EdgeInsets.symmetric(horizontal: 14, vertical: 12);

    // 前缀图标：search 变体自动加搜索图标
    Widget? prefix = widget.prefixIcon;
    if (isSearch && prefix == null) {
      prefix = Icon(Icons.search_rounded, size: 18, color: hintColor);
    }

    final TextField textField = TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      style: TextStyle(
        color: textColor,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.4,
      ),
      cursorColor: AppColors.primary,
      cursorWidth: 1.5,
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: hintColor, fontSize: 14, height: 1.4),
        isDense: true,
        contentPadding: contentPadding,
        // 自定义前缀：受 IconTheme 控制大小与颜色
        prefixIcon: prefix != null
            ? Padding(
                padding: EdgeInsets.only(left: isSearch ? 14 : 12, right: 8),
                child: IconTheme(
                  data: IconThemeData(color: hintColor, size: 18),
                  child: prefix,
                ),
              )
            : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        suffixIcon: widget.suffixIcon != null
            ? Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconTheme(
                  data: IconThemeData(color: hintColor, size: 18),
                  child: widget.suffixIcon!,
                ),
              )
            : null,
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        // 边框由外层 Container 提供，TextField 内部不画边框
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
      ),
    );

    // 输入框本体（含填充 + 描边）
    final Widget inputBox = AnimatedContainer(
      duration: AppMotion.duration(context, AppCurves.durationHover),
      curve: AppCurves.curveHover,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(innerRadius),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: textField,
    );

    // 外层光环（聚焦 / 错误时显示 3px 半透明边框；非聚焦时透明边框占位，避免布局抖动）
    final Widget ringed = AnimatedContainer(
      duration: AppMotion.duration(context, AppCurves.durationHover),
      curve: AppCurves.curveHover,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(outerRadius),
        border: Border.all(
          color: (_focused || hasError) ? ringColor : Colors.transparent,
          width: 3,
        ),
      ),
      child: inputBox,
    );

    // 组装 label + 输入 + error helper
    Widget field = ringed;
    if (widget.label != null || hasError) {
      final children = <Widget>[];
      if (widget.label != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              widget.label!,
              style: TextStyle(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
        );
      }
      children.add(field);
      if (hasError) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: Text(
              widget.errorText!,
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      }
      field = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }

    return field;
  }
}

/// P1 重构：共享的 CRMEB 风格输入框主题。
///
/// 从 add_consumable_sheet / add_filament_cost_sheet / color_picker_panel
/// 三处重复的 _fieldTheme 提取。亮/暗模式自适应。
///
/// 用法：Theme.of(context).copyWith(inputDecorationTheme: appFieldTheme(isDark))
InputDecorationTheme appFieldTheme(bool isDark) => InputDecorationTheme(
  filled: true,
  fillColor: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
  labelStyle: TextStyle(
    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
    fontSize: 13,
  ),
  hintStyle: TextStyle(
    color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
    fontSize: 14,
  ),
  floatingLabelStyle: TextStyle(
    color: AppColors.primary,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  ),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppColors.radiusMd),
    borderSide: BorderSide(
      color: isDark ? AppColors.outlineDark : AppColors.outline,
      width: 1,
    ),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppColors.radiusMd),
    borderSide: BorderSide(color: AppColors.primary, width: 1.5),
  ),
  errorBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppColors.radiusMd),
    borderSide: const BorderSide(color: AppColors.danger, width: 1),
  ),
  focusedErrorBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppColors.radiusMd),
    borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
  ),
);
