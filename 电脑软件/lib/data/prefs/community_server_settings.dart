import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent storage for a runtime community server override.
abstract interface class CommunityServerOverrideStore {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> clear();
}

class SharedPreferencesCommunityServerOverrideStore
    implements CommunityServerOverrideStore {
  static const _key = 'community_api_base_url_override';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  @override
  Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_key, value);
    if (!saved) throw StateError('保存账号服务器地址失败');
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final removed = await prefs.remove(_key);
    if (!removed && prefs.containsKey(_key)) {
      throw StateError('清除账号服务器地址失败');
    }
  }
}

/// Resolves the workbench community API endpoint.
///
/// A runtime override wins over the compile-time `APP_API_BASE_URL` value.
/// Empty configuration is valid and means that community features are not yet
/// configured.
class CommunityServerSettings {
  // Local development builds use the local service. Signed personal builds
  // use the public sohun service unless a staging/self-hosted URL is supplied
  // with APP_API_BASE_URL; a release can never silently connect to localhost.
  static const compiledBaseUrl = String.fromEnvironment(
    'APP_API_BASE_URL',
    // The signed personal build ships against the public sohun API. A
    // dart-define still wins for staging or self-hosted deployments.
    defaultValue:
        kDebugMode ? 'http://127.0.0.1:27861' : 'https://api.sohun.top',
  );

  final CommunityServerOverrideStore store;
  final String compileTimeBaseUrl;
  final bool allowRuntimeOverride;

  CommunityServerSettings({
    required this.store,
    this.compileTimeBaseUrl = compiledBaseUrl,
    bool? allowRuntimeOverride,
  }) : allowRuntimeOverride =
            allowRuntimeOverride ?? compileTimeBaseUrl.trim().isEmpty;

  Future<Uri?> loadBaseUri() async {
    final override = allowRuntimeOverride ? await store.read() : null;
    final selected = allowRuntimeOverride && override?.trim().isNotEmpty == true
        ? override!.trim()
        : compileTimeBaseUrl.trim();
    if (selected.isEmpty) return null;
    return normalizeCommunityServerUri(selected);
  }

  Future<Uri> setOverride(String rawUrl) async {
    if (!allowRuntimeOverride) {
      throw StateError('正式版本的账号服务器已由应用固定，不能在客户端中更换');
    }
    final normalized = normalizeCommunityServerUri(rawUrl);
    await store.write(normalized.toString());
    return normalized;
  }

  Future<Uri?> resetOverride() async {
    await store.clear();
    final compiled = compileTimeBaseUrl.trim();
    if (compiled.isEmpty) return null;
    return normalizeCommunityServerUri(compiled);
  }
}

/// Strictly validates and canonicalizes an HTTP(S) API base URL.
///
/// Credentials, query strings, fragments and path traversal are rejected.
/// The returned URL never ends in `/`, which makes endpoint construction
/// deterministic.
Uri normalizeCommunityServerUri(String rawUrl) {
  final value = rawUrl.trim();
  if (value.isEmpty) throw const FormatException('账号服务器地址不能为空');
  if (RegExp(r'[\x00-\x20\\]').hasMatch(value)) {
    throw const FormatException('账号服务器地址包含无效字符');
  }
  _rejectRawPathTraversal(value);

  late final Uri uri;
  try {
    uri = Uri.parse(value);
  } on FormatException {
    throw const FormatException('账号服务器地址格式不正确');
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') {
    throw const FormatException('账号服务器地址只支持 http 或 https');
  }
  if (!uri.isAbsolute || !uri.hasAuthority || uri.host.isEmpty) {
    throw const FormatException('账号服务器地址必须包含有效域名或 IP');
  }
  if (scheme == 'http' && !_isLoopbackHost(uri.host)) {
    throw const FormatException('非本机账号服务器必须使用 HTTPS');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException('账号服务器地址不能包含用户名或密码');
  }
  if (uri.hasQuery || uri.hasFragment) {
    throw const FormatException('账号服务器地址不能包含查询参数或片段');
  }
  if (uri.pathSegments.any((segment) => segment == '.' || segment == '..')) {
    throw const FormatException('账号服务器地址不能包含路径跳转');
  }

  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';

  int? port;
  if (uri.hasPort) {
    try {
      final candidate = uri.port;
      if (candidate <= 0 || candidate > 65535) {
        throw const FormatException('账号服务器端口无效');
      }
      final isDefault = (scheme == 'https' && candidate == 443) ||
          (scheme == 'http' && candidate == 80);
      if (!isDefault) port = candidate;
    } on FormatException {
      throw const FormatException('账号服务器端口无效');
    }
  }

  return Uri(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    port: port,
    path: path,
  );
}

bool _isLoopbackHost(String host) {
  final value = host.toLowerCase();
  if (value == 'localhost') return true;

  // Never infer loopback status from a textual prefix. A hostname such as
  // `127.attacker.example` is remote even though it begins with `127.`.
  // InternetAddress.tryParse accepts only IP literals here, and isLoopback
  // then covers IPv4 127/8 and compressed/expanded IPv6 loopback forms.
  return InternetAddress.tryParse(value)?.isLoopback ?? false;
}

void _rejectRawPathTraversal(String value) {
  final schemeEnd = value.indexOf('://');
  if (schemeEnd < 0) return;
  final pathStart = value.indexOf('/', schemeEnd + 3);
  if (pathStart < 0) return;
  var rawPath = value.substring(pathStart);
  final suffixStart = rawPath.indexOf(RegExp(r'[?#]'));
  if (suffixStart >= 0) rawPath = rawPath.substring(0, suffixStart);
  for (final rawSegment in rawPath.split('/')) {
    late final String segment;
    try {
      segment = Uri.decodeComponent(rawSegment).toLowerCase();
    } on FormatException {
      throw const FormatException('账号服务器地址包含无效路径编码');
    }
    if (segment == '.' || segment == '..') {
      throw const FormatException('账号服务器地址不能包含路径跳转');
    }
  }
}
