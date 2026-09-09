/// Public HMS protocol: attr is the module word; code is the level/error word.
/// HMS and print_error have separate 16/8-digit namespaces.
String normalizeBambuFaultCode(String value) => value
    .trim()
    .toUpperCase()
    .replaceFirst(RegExp(r'^HMS[_\s-]*'), '')
    .replaceFirst(RegExp(r'^0X'), '')
    .replaceAll(RegExp(r'[-\s]'), '');

int? bambuUnsignedWord(Object? value) {
  final number = value is int
      ? value
      : value is String
      ? (value.toLowerCase().startsWith('0x')
            ? int.tryParse(value.substring(2), radix: 16)
            : int.tryParse(value))
      : null;
  return number != null && number >= 0 && number <= 0xFFFFFFFF ? number : null;
}

String? parseBambuPrintError(Object? value) {
  if (value is String) {
    final code = normalizeBambuFaultCode(value);
    if (code.isEmpty || RegExp(r'^0+$').hasMatch(code)) return '';
    if ((code.length == 8 &&
            (code.startsWith('0') || RegExp('[A-F]').hasMatch(code))) ||
        value.toLowerCase().startsWith('0x') ||
        value.contains('-')) {
      if (!RegExp(r'^[0-9A-F]{1,8}$').hasMatch(code)) return null;
      return code.padLeft(8, '0');
    }
  }
  final number = bambuUnsignedWord(value);
  if (number == null) return null;
  return number == 0
      ? ''
      : number.toRadixString(16).toUpperCase().padLeft(8, '0');
}

String bambuHmsSeverity(String code) => switch (code.length == 16
    ? int.tryParse(code.substring(8, 12), radix: 16)
    : null) {
  1 || 2 => 'error',
  4 => 'info',
  _ => 'warning',
};

Uri? bambuFaultHelpUri(String code, {String? deviceType}) {
  final normalized = normalizeBambuFaultCode(code);
  if (!RegExp(r'^(?:[0-9A-F]{8}|[0-9A-F]{16})$').hasMatch(normalized))
    return null;
  return Uri.https('e.bambulab.com', '/index.php', {
    'e': normalized,
    's': normalized.length == 16 ? 'device_hms' : 'device_error',
    'lang': 'zh-cn',
    if (deviceType != null && RegExp(r'^[0-9A-Za-z]{3}$').hasMatch(deviceType))
      'd': deviceType,
  });
}
