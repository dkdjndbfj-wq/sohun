import 'dart:io';

/// 解析可安全自动加载的公网 HTTPS 图片地址。
///
/// 这是客户端的纵深防御：社区数据即使来自旧服务端或被篡改，也不能让
/// Image.network 自动访问回环、私网、链路本地或明显的本地域名。
Uri? parsePublicHttpsImageUrl(
  String? rawValue, {
  Uri? trustedOrigin,
}) {
  final value = rawValue?.trim();
  if (value == null || value.isEmpty || value.length > 1000) return null;
  late final Uri uri;
  try {
    uri = Uri.parse(value);
  } on FormatException {
    return null;
  }
  if (uri.scheme.toLowerCase() != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      _isBlockedHost(uri.host) ||
      trustedOrigin == null ||
      trustedOrigin.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != trustedOrigin.host.toLowerCase() ||
      uri.port != trustedOrigin.port) {
    return null;
  }
  return uri;
}

/// 本地图片引用不能带 URI scheme/authority，避免不安全远程 URL 被误当成路径。
bool isLocalImageReference(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  try {
    final uri = Uri.parse(trimmed);
    return !uri.hasScheme && !uri.hasAuthority;
  } on FormatException {
    return false;
  }
}

bool _isBlockedHost(String rawHost) {
  final host = rawHost.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final address = InternetAddress.tryParse(host);
  if (address != null) return _isBlockedAddress(address);
  // Uri 不会像浏览器/Node 一样把 127.1、0177.0.0.1 等非标准数字写法
  // 规范化为 IPv4；全部由数字和点组成的主机名一律拒绝，避免解析差异绕过。
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return true;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (const ['.local', '.lan', '.internal', '.home', '.arpa']
      .any(host.endsWith)) {
    return true;
  }
  if (!host.contains('.') || host.length > 253) return true;
  final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$');
  return host.split('.').any(
        (label) =>
            label.isEmpty || label.length > 63 || !labelPattern.hasMatch(label),
      );
}

bool _isBlockedAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return _isBlockedIpv4(bytes);
  }
  if (bytes.length != 16) return true;
  final allZero = bytes.every((byte) => byte == 0);
  final loopback = bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  if (allZero || loopback) return true;
  if ((bytes[0] & 0xfe) == 0xfc ||
      (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) ||
      bytes[0] == 0xff) {
    return true;
  }
  // IPv6 documentation prefix 2001:db8::/32 is not globally routable.
  if (bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8) {
    return true;
  }
  final mappedIpv4 = bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (mappedIpv4) return _isBlockedIpv4(bytes.sublist(12));
  return false;
}

bool _isBlockedIpv4(List<int> bytes) {
  if (bytes.length != 4) return true;
  final a = bytes[0];
  final b = bytes[1];
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 0) ||
      (a == 192 && b == 168) ||
      (a == 198 && (b == 18 || b == 19)) ||
      a >= 224;
}
