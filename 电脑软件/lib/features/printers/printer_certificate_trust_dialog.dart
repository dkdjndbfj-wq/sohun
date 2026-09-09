import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_certificate_trust_store.dart';

class PrinterCertificateProbe {
  const PrinterCertificateProbe({
    required this.fingerprint,
    required this.subject,
    required this.issuer,
    required this.startValidity,
    required this.endValidity,
  });

  final String fingerprint;
  final String subject;
  final String issuer;
  final DateTime startValidity;
  final DateTime endValidity;
}

typedef PrinterCertificateProbeLoader = Future<PrinterCertificateProbe>
    Function(String host, int port);

/// Opens TLS only long enough to inspect the peer certificate. No MQTT
/// credentials or LAN access code are sent during this probe.
Future<PrinterCertificateProbe> probePrinterCertificate(
  String host,
  int port,
) async {
  SecureSocket? socket;
  X509Certificate? certificate;
  try {
    socket = await SecureSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
      onBadCertificate: (candidate) {
        certificate = candidate;
        return true;
      },
    );
    certificate ??= socket.peerCertificate;
    final peer = certificate;
    if (peer == null) {
      throw const HandshakeException('打印机未提供 TLS 证书');
    }
    return PrinterCertificateProbe(
      fingerprint: PrinterCertificateTrustStore.fingerprintForDer(peer.der),
      subject: peer.subject,
      issuer: peer.issuer,
      startValidity: peer.startValidity,
      endValidity: peer.endValidity,
    );
  } finally {
    socket?.destroy();
  }
}

Future<bool> confirmPrinterCertificateTrust(
  BuildContext context,
  PrinterConnectionConfig config, {
  PrinterCertificateProbeLoader probe = probePrinterCertificate,
}) async {
  if (config.mode != BambuConnectionMode.lan) return true;
  if (await PrinterCertificateTrustStore.hasTrust(
    serial: config.serial,
    host: config.host,
    service: PrinterTlsService.mqtt,
  )) {
    return true;
  }

  late final PrinterCertificateProbe result;
  try {
    result = await probe(config.host, config.port);
  } catch (error) {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法验证打印机证书'),
        content: Text('无法读取 ${config.host}:${config.port} 的 TLS 证书。\n\n$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    return false;
  }

  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认打印机证书'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设备：${config.displayLabel}'),
                  Text('地址：${config.host}:${config.port}'),
                  const SizedBox(height: 12),
                  const Text('SHA-256 指纹'),
                  const SizedBox(height: 4),
                  SelectableText(
                    _formatFingerprint(result.fingerprint),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 12),
                  Text('主题：${result.subject}'),
                  Text('签发者：${result.issuer}'),
                  Text(
                    '有效期：${_formatDate(result.startValidity)} 至 '
                    '${_formatDate(result.endValidity)}',
                  ),
                  const SizedBox(height: 12),
                  const Text('请与打印机或受信任的管理信息核对指纹。以后证书发生变化时，连接会被拒绝。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('信任此证书'),
            ),
          ],
        ),
      ) ??
      false;
  if (!accepted) return false;

  await PrinterCertificateTrustStore.trustFingerprint(
    serial: config.serial,
    host: config.host,
    service: PrinterTlsService.mqtt,
    fingerprint: result.fingerprint,
  );
  return true;
}

/// 批量验证并一次确认多台打印机证书。任何设备探测失败时整批停止，避免
/// 用户误以为所有选中设备都已经安全加入。
Future<bool> confirmPrinterCertificatesTrust(
  BuildContext context,
  Iterable<PrinterConnectionConfig> configs, {
  PrinterCertificateProbeLoader probe = probePrinterCertificate,
}) async {
  final unique = <String, PrinterConnectionConfig>{};
  for (final config in configs) {
    if (config.mode != BambuConnectionMode.lan) continue;
    unique['${config.serial}\u0000${config.host}\u0000${config.port}'] = config;
  }
  final pending = <PrinterConnectionConfig>[];
  for (final config in unique.values) {
    final trusted = await PrinterCertificateTrustStore.hasTrust(
      serial: config.serial,
      host: config.host,
      service: PrinterTlsService.mqtt,
    );
    if (!trusted) pending.add(config);
  }
  if (pending.isEmpty) return true;

  final results = await Future.wait(
    pending.map((config) async {
      try {
        return _BatchCertificateResult(
          config: config,
          probe: await probe(config.host, config.port),
        );
      } catch (error) {
        return _BatchCertificateResult(config: config, error: error);
      }
    }),
  );
  if (!context.mounted) return false;
  final failures = results.where((result) => result.error != null).toList();
  if (failures.isNotEmpty) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('部分打印机证书无法验证'),
        content: SizedBox(
          width: 560,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: failures.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final failure = failures[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.error_outline),
                title: Text(failure.config.displayLabel),
                subtitle: Text(
                  '${failure.config.host}:${failure.config.port}\n${failure.error}',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('返回检查'),
          ),
        ],
      ),
    );
    return false;
  }

  final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text('确认 ${results.length} 台打印机证书'),
          content: SizedBox(
            width: 620,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final result = results[index];
                final certificate = result.probe!;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(result.config.displayLabel),
                  subtitle: Text(
                    '${result.config.host}:${result.config.port}\n'
                    'SHA-256 ${_formatFingerprint(certificate.fingerprint)}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.playlist_add_check_outlined),
              label: const Text('信任并批量添加'),
            ),
          ],
        ),
      ) ??
      false;
  if (!accepted) return false;

  for (final result in results) {
    await PrinterCertificateTrustStore.trustFingerprint(
      serial: result.config.serial,
      host: result.config.host,
      service: PrinterTlsService.mqtt,
      fingerprint: result.probe!.fingerprint,
    );
  }
  return true;
}

class _BatchCertificateResult {
  const _BatchCertificateResult({
    required this.config,
    this.probe,
    this.error,
  });

  final PrinterConnectionConfig config;
  final PrinterCertificateProbe? probe;
  final Object? error;
}

String _formatFingerprint(String value) {
  final normalized = value.toUpperCase();
  return [
    for (var offset = 0; offset < normalized.length; offset += 2)
      normalized.substring(offset, offset + 2),
  ].join(':');
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
