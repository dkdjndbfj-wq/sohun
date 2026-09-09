import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// The third-party shop is shown in the support page instead of replacing the
/// account-linked interaction above it. WebView2 is Windows-only; unsupported
/// platforms and machines without the WebView2 runtime get a safe browser
/// fallback rather than a blank or crashing panel.
class SupportShopEmbed extends StatefulWidget {
  const SupportShopEmbed({super.key});

  static const shopUrl = 'https://pay.ldxp.cn/shop/Salcara';

  @override
  State<SupportShopEmbed> createState() => _SupportShopEmbedState();
}

class _SupportShopEmbedState extends State<SupportShopEmbed> {
  WebviewController? _controller;
  bool _controllerInitialized = false;
  bool _loading = true;
  String? _error;

  bool get _canEmbed =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_canEmbed) {
      unawaited(_initialize());
    } else {
      _loading = false;
      _error = '当前平台不支持内嵌商城';
    }
  }

  Future<void> _initialize() async {
    final controller = WebviewController();
    _controller = controller;
    try {
      await controller.initialize();
      _controllerInitialized = true;
      await controller
          .setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      await controller.loadUrl(SupportShopEmbed.shopUrl);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyWebviewError(error);
      });
    }
  }

  Future<void> _reload() async {
    if (!_canEmbed) {
      setState(() {
        _loading = false;
        _error = '当前平台不支持内嵌商城';
      });
      return;
    }
    final controller = _controller;
    if (controller == null || !_controllerInitialized) {
      setState(() {
        _loading = true;
        _error = null;
      });
      await _initialize();
      return;
    }
    setState(() => _loading = true);
    try {
      await controller.reload();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyWebviewError(error);
      });
    }
  }

  Future<void> _openExternal() async {
    final opened = await launchUrl(
      Uri.parse(SupportShopEmbed.shopUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开商城链接，请复制后在浏览器访问')),
      );
    }
  }

  String _friendlyWebviewError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('environment_creation_failed') ||
        text.contains('webview2') ||
        text.contains('missingplugin')) {
      return '本机未检测到 WebView2 运行时，请安装后重试；也可以改用外部浏览器打开商城。';
    }
    return '商城暂时无法加载，请重试或改用外部浏览器。';
  }

  @override
  void dispose() {
    final controller = _controller;
    if (_controllerInitialized && controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final border = scheme.outlineVariant.withValues(alpha: 0.62);
    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF18201E) : scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
            child: Row(
              children: [
                Icon(Icons.shopping_bag_outlined,
                    color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '支持商城',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontFamily: AppTypography.chineseFontFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '在这里选择支持商品，支付完成后返回卡密，再到上方绑定。',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新商城',
                  onPressed: _loading ? null : () => unawaited(_reload()),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
                if (_error == null)
                  IconButton(
                    tooltip: '用浏览器打开',
                    onPressed: () => unawaited(_openExternal()),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 620,
            child: _error != null
                ? _FallbackPanel(
                    message: _error!,
                    onRetry: () => unawaited(_reload()),
                    onOpenExternal: () => unawaited(_openExternal()),
                  )
                : _controllerInitialized && _controller != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Webview(_controller!),
                          if (_loading)
                            const ColoredBox(
                              color: Colors.white,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                        ],
                      )
                    : const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
            child: Row(
              children: [
                Icon(Icons.lock_outline_rounded,
                    size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '商城由第三方提供，付款与卡密请以商城页面显示为准。需要在浏览器中完成支付时，请使用标题栏右侧的打开按钮。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackPanel extends StatelessWidget {
  const _FallbackPanel({
    required this.message,
    required this.onRetry,
    required this.onOpenExternal,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.web_asset_off_rounded,
                  size: 42, color: scheme.primary),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重试'),
                  ),
                  FilledButton.icon(
                    onPressed: onOpenExternal,
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
