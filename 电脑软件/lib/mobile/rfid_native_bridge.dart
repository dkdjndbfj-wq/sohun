import 'dart:async';

import 'package:flutter/services.dart';

import 'ams_tag_template.dart';
import 'mobile_rfid_models.dart';

/// Result of a native NFC write attempt.
sealed class RfidWriteResult {
  const RfidWriteResult();
}

class RfidWriteSuccess extends RfidWriteResult {
  final String? tagId;

  /// Carrier metadata reported by Android (for example user-declared `CUID`).
  ///
  /// Write results contain metadata only. Complete templates cross a separate
  /// local-only NFC/vault boundary and must never enter inventory sync records.
  final String? tagType;
  final String? technology;
  final int? bytesWritten;
  final int? blocksWritten;
  final int? blocksVerified;
  final int? writableBlocks;
  final bool? verified;

  /// Successful NFC readback alone does not verify real AMS compatibility.
  final String amsCompatibility;

  const RfidWriteSuccess({
    this.tagId,
    this.tagType,
    this.technology,
    this.bytesWritten,
    this.blocksWritten,
    this.blocksVerified,
    this.writableBlocks,
    this.verified,
    this.amsCompatibility = 'not_verified',
  });

  bool get amsCompatibilityVerified {
    final normalized = amsCompatibility.trim().toLowerCase();
    return normalized == 'verified' ||
        normalized == 'compatible' ||
        normalized == 'supported';
  }
}

class RfidWriteFailure extends RfidWriteResult {
  final String code;
  final String message;

  const RfidWriteFailure(this.code, this.message);
}

/// Compatibility result for the retired NTAG consumable-record reader.
/// The native bridge rejects this purpose; NTAG213 never imports inventory.
sealed class RfidReadResult {
  const RfidReadResult();
}

class RfidReadSuccess extends RfidReadResult {
  final MobileConsumableDraft draft;
  final String? tagId;
  final String? tagType;
  final String? technology;
  final int? bytesRead;
  final int? pagesRead;
  final bool verified;

  const RfidReadSuccess({
    required this.draft,
    this.tagId,
    this.tagType,
    this.technology,
    this.bytesRead,
    this.pagesRead,
    this.verified = true,
  });
}

class RfidReadFailure extends RfidReadResult {
  final String code;
  final String message;

  const RfidReadFailure(this.code, this.message);
}

/// Result of a read-only MIFARE Classic metadata scan.
///
/// The scan is intentionally not a dump reader. It returns the UID and card
/// geometry plus a count of ordinary data blocks that accepted the default
/// blank-card key. Block bytes, keys, UID-write capability and vendor
/// signatures never cross the platform boundary.
sealed class RfidScanResult {
  const RfidScanResult();
}

class RfidMifareScanSuccess extends RfidScanResult {
  final String? tagId;
  final String? tagType;
  final String? technology;
  final int? sizeBytes;
  final int? blockCount;
  final int? sectorCount;
  final int? uidLengthBytes;
  final int? defaultKeyAuthenticatedSectors;
  final int? defaultKeyReadableSectors;
  final int? defaultKeyReadableBlocks;
  final bool defaultKeyReadable;

  const RfidMifareScanSuccess({
    this.tagId,
    this.tagType,
    this.technology,
    this.sizeBytes,
    this.blockCount,
    this.sectorCount,
    this.uidLengthBytes,
    this.defaultKeyAuthenticatedSectors,
    this.defaultKeyReadableSectors,
    this.defaultKeyReadableBlocks,
    this.defaultKeyReadable = false,
  });

  /// True when the card looks like the 4-byte UID carrier expected by CUID /
  /// FUID test media. This describes the UID shape only; it does not prove
  /// that the UID can be changed or that AMS will accept the card.
  bool get hasFourByteUid => uidLengthBytes == 4;
}

class RfidScanFailure extends RfidScanResult {
  final String code;
  final String message;

  const RfidScanFailure(this.code, this.message);
}

/// Compatibility interface for callers of the retired NTAG inventory reader.
/// Implementations must reject NTAG consumable reads without activating NFC.
abstract interface class RfidTagReader {
  Future<RfidReadResult> read();
}

/// Optional read-only scanner used by the batch inventory workflow.
///
/// Implementations must never write block 0, sector trailers, keys or raw
/// vendor dumps. The Android implementation only returns safe metadata.
abstract interface class RfidTagScanner {
  Future<RfidScanResult> scanMifareClassic();
}

/// Platform boundary for Android NFC writing.
///
/// The Android host owns tag discovery and sector access. Keeping this API
/// small lets the UI run in widget tests and lets the desktop host inject a
/// simulator while Android support is being set up.
abstract interface class RfidNativeBridge {
  Future<bool> isAvailable();

  Future<bool> isEnabled();

  Future<RfidWriteResult> write(MobileConsumableDraft draft);

  Future<void> cancel();
}

/// Optional write-profile capability exposed by Android.
///
/// The legacy `ams` record profile is rejected: callers must use
/// [AmsTemplateNfc.restoreAmsTemplate] with complete source data. The legacy
/// `ntag213` consumable profile is also rejected: only CUID/FUID participate
/// in the custom consumable inventory workflow.
abstract interface class RfidProfileWriter {
  Future<RfidWriteResult> writeProfile(
    MobileConsumableDraft draft, {
    required String profile,
  });
}

sealed class AmsTemplateReadResult {
  const AmsTemplateReadResult();
}

class AmsTemplateReadSuccess extends AmsTemplateReadResult {
  const AmsTemplateReadSuccess(this.template);
  final AmsTagTemplate template;
}

class AmsTemplateReadFailure extends AmsTemplateReadResult {
  const AmsTemplateReadFailure(this.code, this.message);
  final String code;
  final String message;
}

/// Local-only complete template operations. No third-party inventory fields
/// are accepted here: signed source bytes must remain unchanged.
abstract interface class AmsTemplateNfc {
  Future<AmsTemplateReadResult> readAmsTemplate();

  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  });
}

/// Android implementation backed by the `top.sohun/consumable_rfid` channel.
class MethodChannelRfidNativeBridge
    implements
        RfidNativeBridge,
        RfidTagReader,
        RfidTagScanner,
        RfidProfileWriter,
        AmsTemplateNfc {
  static const channelName = 'top.sohun/consumable_rfid';

  /// Android owns the operation deadline and publishes a terminal event at
  /// these limits. The Dart waits include a small delivery grace so the
  /// native result wins instead of racing a second cancellation at the same
  /// boundary.
  static const nativeAmsTemplateReadTimeout = Duration(seconds: 120);
  static const nativeAmsTemplateRestoreTimeout = Duration(seconds: 180);
  static const nativeTimeoutDeliveryGrace = Duration(seconds: 5);
  static const defaultAmsTemplateReadWaitTimeout = Duration(seconds: 125);
  static const defaultAmsTemplateRestoreWaitTimeout = Duration(seconds: 185);

  MethodChannelRfidNativeBridge({
    MethodChannel? methodChannel,
    Duration amsTemplateReadWaitTimeout = defaultAmsTemplateReadWaitTimeout,
    Duration amsTemplateRestoreWaitTimeout =
        defaultAmsTemplateRestoreWaitTimeout,
  }) : channel = methodChannel ?? const MethodChannel(channelName),
       _amsTemplateReadWaitTimeout = amsTemplateReadWaitTimeout,
       _amsTemplateRestoreWaitTimeout = amsTemplateRestoreWaitTimeout;

  final MethodChannel channel;
  final Duration _amsTemplateReadWaitTimeout;
  final Duration _amsTemplateRestoreWaitTimeout;
  String? _activeOperationId;
  Completer<RfidWriteResult>? _activeCompleter;
  Completer<RfidScanResult>? _activeScanCompleter;
  Completer<AmsTemplateReadResult>? _activeTemplateReadCompleter;

  static String _newOperationId() =>
      'mobile-${DateTime.now().microsecondsSinceEpoch}';

  @override
  Future<bool> isAvailable() async {
    try {
      final value = await channel.invokeMethod<Object?>('getStatus');
      return value is Map && value['available'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> isEnabled() async {
    try {
      final value = await channel.invokeMethod<Object?>('getStatus');
      return value is Map && value['enabled'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) {
    return writeProfile(draft, profile: 'ams');
  }

  @override
  Future<RfidWriteResult> writeProfile(
    MobileConsumableDraft draft, {
    required String profile,
  }) async {
    switch (profile.trim().toLowerCase()) {
      case 'ams':
        return const RfidWriteFailure(
          'ams_template_required',
          'AMS 写入需要完整兼容标签模板，不能仅写入品牌和型号',
        );
      case 'ntag213':
        return const RfidWriteFailure(
          'unsupported_tag_purpose',
          'NTAG213 不用于耗材资料或库存；请使用 CUID/FUID 耗材流程',
        );
      default:
        return const RfidWriteFailure('invalid_profile', '未知的 NFC 写入模式');
    }
  }

  @override
  Future<RfidReadResult> read() async => const RfidReadFailure(
    'unsupported_tag_purpose',
    'NTAG213 不用于耗材读取入库；请使用 CUID/FUID 耗材流程',
  );

  @override
  Future<RfidScanResult> scanMifareClassic() async {
    if (_activeOperationId != null) {
      return const RfidScanFailure('nfc_busy', '已有一个 NFC 操作正在进行');
    }
    final operationId = _newOperationId();
    _activeOperationId = operationId;
    final resultCompleter = Completer<RfidScanResult>();
    _activeScanCompleter = resultCompleter;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'rfidEvent' || call.arguments is! Map) return null;
      final event = Map<Object?, Object?>.from(call.arguments as Map);
      if (event['operationId']?.toString() != operationId) return null;
      final parsed = _scanResultFromEvent(event);
      if (parsed != null && !resultCompleter.isCompleted) {
        resultCompleter.complete(parsed);
      }
      return null;
    });
    try {
      await channel.invokeMethod<Object?>('beginScan', <String, Object>{
        'operationId': operationId,
        'profile': 'mifareClassic',
      });
      return await resultCompleter.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () async {
          try {
            await cancel();
          } catch (_) {
            // The timeout result remains deterministic if Android has already
            // left reader mode.
          }
          return const RfidScanFailure(
            'scan_timeout',
            '等待标签超时，请确认 NFC 已开启并重新靠近 CUID/FUID 标签',
          );
        },
      );
    } on PlatformException catch (error) {
      return RfidScanFailure(error.code, error.message ?? 'NFC 服务暂不可用');
    } on MissingPluginException {
      return const RfidScanFailure(
        'unsupported_platform',
        '当前设备未提供 MIFARE Classic 扫描服务',
      );
    } finally {
      if (_activeOperationId == operationId) {
        _activeOperationId = null;
        _activeScanCompleter = null;
      }
      channel.setMethodCallHandler(null);
    }
  }

  @override
  Future<AmsTemplateReadResult> readAmsTemplate() async {
    if (_activeOperationId != null) {
      return const AmsTemplateReadFailure('nfc_busy', '已有一个 NFC 操作正在进行');
    }
    final operationId = _newOperationId();
    final completer = Completer<AmsTemplateReadResult>();
    _activeOperationId = operationId;
    _activeTemplateReadCompleter = completer;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'rfidEvent' || call.arguments is! Map) return null;
      final event = Map<Object?, Object?>.from(call.arguments as Map);
      if (event['operationId'] != operationId) return null;
      final result = _templateReadFromEvent(event);
      if (result != null && !completer.isCompleted) completer.complete(result);
      return null;
    });
    try {
      await channel.invokeMethod<Object?>('beginReadAmsTemplate', {
        'operationId': operationId,
      });
      return await completer.future.timeout(
        _amsTemplateReadWaitTimeout,
        onTimeout: () async {
          try {
            await cancel();
          } catch (_) {
            /* Preserve timeout result. */
          }
          return const AmsTemplateReadFailure(
            'template_read_timeout',
            '读取超时，请重新贴近源标签',
          );
        },
      );
    } on PlatformException catch (error) {
      return AmsTemplateReadFailure(error.code, error.message ?? '读取模板失败');
    } on MissingPluginException {
      return const AmsTemplateReadFailure(
        'unsupported_platform',
        '当前设备未提供完整模板读取服务',
      );
    } finally {
      if (_activeOperationId == operationId) {
        _activeOperationId = null;
        _activeTemplateReadCompleter = null;
        channel.setMethodCallHandler(null);
      }
    }
  }

  @override
  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  }) async {
    if (!allowUidChange || !const ['cuid', 'fuid'].contains(targetKind)) {
      return const RfidWriteFailure(
        'uid_confirmation_required',
        '请先确认目标卡类型及覆盖 UID 的风险',
      );
    }
    if (_activeOperationId != null) {
      return const RfidWriteFailure('nfc_busy', '已有一个 NFC 操作正在进行');
    }
    final operationId = _newOperationId();
    final completer = Completer<RfidWriteResult>();
    _activeOperationId = operationId;
    _activeCompleter = completer;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'rfidEvent' || call.arguments is! Map) return null;
      final event = Map<Object?, Object?>.from(call.arguments as Map);
      if (event['operationId'] != operationId) return null;
      final parsed = _resultFromEvent(event);
      if (parsed != null && !completer.isCompleted) {
        completer.complete(parsed);
      } else if (parsed == null && !completer.isCompleted) {
        onProgress?.call(event['state']?.toString() ?? 'writing');
      }
      return null;
    });
    try {
      await channel.invokeMethod<Object?>('beginRestoreAmsTemplate', {
        'operationId': operationId,
        'template': template.toJson(),
        'targetKind': targetKind,
        'allowUidChange': true,
      });
      final result = await completer.future.timeout(
        _amsTemplateRestoreWaitTimeout,
        onTimeout: () async {
          try {
            await cancel();
          } catch (_) {
            /* Preserve timeout result. */
          }
          return const RfidWriteFailure(
            'write_timeout',
            '模板写入超时，标签可能只写入了一部分；请重新检查，不要放入 AMS',
          );
        },
      );
      if (result is RfidWriteSuccess &&
          (result.verified != true ||
              result.blocksVerified != 64 ||
              result.tagId?.toUpperCase() != template.uid.toUpperCase() ||
              result.amsCompatibility != 'template_restored_unverified')) {
        return const RfidWriteFailure(
          'template_verification_incomplete',
          '尚未完成模板和真实 UID 的完整校验，未加入库存',
        );
      }
      return result;
    } on PlatformException catch (error) {
      return RfidWriteFailure(error.code, error.message ?? '模板写入失败');
    } on MissingPluginException {
      return const RfidWriteFailure('unsupported_platform', '当前设备未提供兼容模板写入服务');
    } finally {
      if (_activeOperationId == operationId) {
        _activeOperationId = null;
        _activeCompleter = null;
        channel.setMethodCallHandler(null);
      }
    }
  }

  AmsTemplateReadResult? _templateReadFromEvent(Map<Object?, Object?> event) {
    if (event['state'] == 'template_read_success') {
      try {
        final raw = event['template'];
        if (raw is! Map) throw const FormatException('missing template');
        return AmsTemplateReadSuccess(
          AmsTagTemplate.fromJson(Map<String, dynamic>.from(raw)),
        );
      } catch (_) {
        return const AmsTemplateReadFailure(
          'invalid_template',
          '源标签数据不完整或结构无效，未保存模板',
        );
      }
    }
    if (event['state'] == 'failed' || event['state'] == 'cancelled') {
      return AmsTemplateReadFailure(
        event['code']?.toString() ?? 'template_read_failed',
        event['message']?.toString() ?? '模板读取失败',
      );
    }
    return null;
  }

  @override
  Future<void> cancel() async {
    final operationId = _activeOperationId;
    if (operationId == null) return;
    final completer = _activeCompleter;
    final scanCompleter = _activeScanCompleter;
    final templateCompleter = _activeTemplateReadCompleter;
    try {
      final response = await channel.invokeMethod<Object?>(
        'cancel',
        <String, Object>{'operationId': operationId},
      );
      if (response is Map) {
        final event = Map<Object?, Object?>.from(response);
        if (event['operationId']?.toString() == operationId) {
          final parsed = _resultFromEvent(event);
          if (parsed != null && completer != null && !completer.isCompleted) {
            completer.complete(parsed);
          }
          final scanParsed = _scanResultFromEvent(event);
          if (scanParsed != null &&
              scanCompleter != null &&
              !scanCompleter.isCompleted) {
            scanCompleter.complete(scanParsed);
          }
          final templateParsed = _templateReadFromEvent(event);
          if (templateParsed != null &&
              templateCompleter != null &&
              !templateCompleter.isCompleted) {
            templateCompleter.complete(templateParsed);
          }
        }
      }
    } on MissingPluginException {
      // Desktop/widget-test hosts do not register the Android channel.
    } on PlatformException catch (error) {
      if (error.code != 'OPERATION_NOT_FOUND') rethrow;
      final terminal = await _readTerminalResult(operationId);
      if (terminal != null && completer != null && !completer.isCompleted) {
        completer.complete(terminal);
      }
      final scanTerminal = await _readTerminalScanResult(operationId);
      if (scanTerminal != null &&
          scanCompleter != null &&
          !scanCompleter.isCompleted) {
        scanCompleter.complete(scanTerminal);
      }
      if (templateCompleter != null && !templateCompleter.isCompleted) {
        try {
          final response = await channel.invokeMethod<Object?>(
            'getOperationState',
            {'operationId': operationId},
          );
          if (response is Map && response['operationId'] == operationId) {
            final parsed = _templateReadFromEvent(
              Map<Object?, Object?>.from(response),
            );
            if (parsed != null && !templateCompleter.isCompleted) {
              templateCompleter.complete(parsed);
            }
          }
        } on PlatformException {
          /* Fall through to cancellation. */
        } on MissingPluginException {
          /* No Android host. */
        }
      }
    } finally {
      if (completer != null && !completer.isCompleted) {
        completer.complete(
          const RfidWriteFailure('write_cancelled', 'RFID 操作已取消'),
        );
      }
      if (scanCompleter != null && !scanCompleter.isCompleted) {
        scanCompleter.complete(
          const RfidScanFailure('scan_cancelled', 'RFID 扫描已取消'),
        );
      }
      if (templateCompleter != null && !templateCompleter.isCompleted) {
        templateCompleter.complete(
          const AmsTemplateReadFailure('template_read_cancelled', '模板读取已取消'),
        );
      }
    }
  }

  Future<RfidWriteResult?> _readTerminalResult(String operationId) async {
    try {
      final response = await channel.invokeMethod<Object?>(
        'getOperationState',
        <String, Object>{'operationId': operationId},
      );
      if (response is! Map) return null;
      final event = Map<Object?, Object?>.from(response);
      if (event['operationId']?.toString() != operationId) return null;
      return _resultFromEvent(event);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<RfidScanResult?> _readTerminalScanResult(String operationId) async {
    try {
      final response = await channel.invokeMethod<Object?>(
        'getOperationState',
        <String, Object>{'operationId': operationId},
      );
      if (response is! Map) return null;
      final event = Map<Object?, Object?>.from(response);
      if (event['operationId']?.toString() != operationId) return null;
      return _scanResultFromEvent(event);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  RfidWriteResult? _resultFromEvent(Map<Object?, Object?> event) {
    final state = event['state']?.toString();
    if (state == 'success' || state == 'write_success') {
      final rawTag = event['tag'];
      final nestedTag = rawTag is Map
          ? Map<Object?, Object?>.from(rawTag)
          : const <Object?, Object?>{};
      final rawVerification = event['verification'];
      final verification = rawVerification is Map
          ? Map<Object?, Object?>.from(rawVerification)
          : const <Object?, Object?>{};
      final nestedTagId =
          nestedTag['tagId']?.toString() ?? nestedTag['uid']?.toString();
      final rawAmsCompatibility =
          event['amsCompatibility'] ??
          event['amsCompatibilityStatus'] ??
          (event['amsCompatible'] is bool
              ? ((event['amsCompatible'] as bool) ? 'verified' : 'not_verified')
              : null);
      final verificationText = rawVerification?.toString().trim().toLowerCase();
      return RfidWriteSuccess(
        tagId:
            event['tagId']?.toString() ??
            event['trayUuid']?.toString() ??
            nestedTagId,
        tagType:
            event['tagType']?.toString() ??
            event['type']?.toString() ??
            nestedTag['type']?.toString() ??
            nestedTag['tagType']?.toString(),
        technology:
            event['technology']?.toString() ??
            nestedTag['technology']?.toString(),
        bytesWritten: _optionalInt(
          event['bytesWritten'] ??
              verification['bytesWritten'] ??
              nestedTag['bytesWritten'],
        ),
        blocksWritten: _optionalInt(
          event['blocksWritten'] ??
              verification['blocksWritten'] ??
              nestedTag['blocksWritten'],
        ),
        blocksVerified: _optionalInt(
          event['blocksVerified'] ??
              verification['blocksVerified'] ??
              nestedTag['blocksVerified'],
        ),
        writableBlocks: _optionalInt(
          event['writableBlocks'] ??
              verification['writableBlocks'] ??
              nestedTag['writableBlocks'],
        ),
        verified: _optionalBool(
          event['verified'] ??
              event['verificationPassed'] ??
              verification['verified'] ??
              nestedTag['verified'] ??
              (verificationText == 'passed'
                  ? true
                  : verificationText == 'failed' ||
                        verificationText == 'not_completed'
                  ? false
                  : null),
        ),
        amsCompatibility: rawAmsCompatibility?.toString() ?? 'not_verified',
      );
    }
    if (state == 'failed' || state == 'cancelled') {
      return RfidWriteFailure(
        event['code']?.toString() ?? 'write_failed',
        event['message']?.toString() ?? '标签写入失败',
      );
    }
    return null;
  }

  RfidScanResult? _scanResultFromEvent(Map<Object?, Object?> event) {
    final state = event['state']?.toString();
    if (state == 'scan_success') {
      final rawTag = event['tag'];
      final nestedTag = rawTag is Map
          ? Map<Object?, Object?>.from(rawTag)
          : const <Object?, Object?>{};
      final readBool = _optionalBool(
        event['defaultKeyReadable'] ?? nestedTag['defaultKeyReadable'],
      );
      return RfidMifareScanSuccess(
        tagId: event['tagId']?.toString() ?? nestedTag['uid']?.toString(),
        tagType:
            event['tagType']?.toString() ??
            event['type']?.toString() ??
            nestedTag['type']?.toString() ??
            nestedTag['tagType']?.toString(),
        technology:
            event['technology']?.toString() ??
            nestedTag['technology']?.toString(),
        sizeBytes: _optionalInt(event['sizeBytes'] ?? nestedTag['sizeBytes']),
        blockCount: _optionalInt(
          event['blockCount'] ?? nestedTag['blockCount'],
        ),
        sectorCount: _optionalInt(
          event['sectorCount'] ?? nestedTag['sectorCount'],
        ),
        uidLengthBytes: _optionalInt(
          event['uidLengthBytes'] ?? nestedTag['uidLengthBytes'],
        ),
        defaultKeyAuthenticatedSectors: _optionalInt(
          event['defaultKeyAuthenticatedSectors'] ??
              nestedTag['defaultKeyAuthenticatedSectors'],
        ),
        defaultKeyReadableSectors: _optionalInt(
          event['defaultKeyReadableSectors'] ??
              nestedTag['defaultKeyReadableSectors'],
        ),
        defaultKeyReadableBlocks: _optionalInt(
          event['defaultKeyReadableBlocks'] ??
              nestedTag['defaultKeyReadableBlocks'],
        ),
        defaultKeyReadable: readBool ?? false,
      );
    }
    if (state == 'failed' || state == 'cancelled') {
      return RfidScanFailure(
        event['code']?.toString() ?? 'scan_failed',
        event['message']?.toString() ?? 'MIFARE 标签扫描失败',
      );
    }
    return null;
  }

  int? _optionalInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool? _optionalBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case 'yes':
        case '1':
          return true;
        case 'false':
        case 'no':
        case '0':
          return false;
      }
    }
    return null;
  }
}

/// Sync boundary owned by the host app. The mobile UI should not invent an
/// account API; the desktop project can inject its eventual sohun adapter.
class MobileInventorySaveResult {
  const MobileInventorySaveResult({
    required this.inventoryUid,
    this.rfidTagUid,
    this.rfidTagCycle = 1,
    this.createdNewCycle = false,
    this.requiresReplacement = false,
    this.syncPending = false,
  });

  /// Stable ID of the concrete spool row written to inventory.
  final String inventoryUid;

  /// Canonical reusable physical tag identity, if the row has one.
  final String? rfidTagUid;

  /// Reuse number for this tag (1 for the first spool).
  final int rfidTagCycle;
  final bool createdNewCycle;

  /// True when the scanned tag resolves to a depleted/replaced/retired spool.
  /// The caller must ask for an explicit replacement before treating a new
  /// physical roll as the next cycle.
  final bool requiresReplacement;
  final bool syncPending;

  MobileInventorySaveResult withPendingSync() => MobileInventorySaveResult(
    inventoryUid: inventoryUid,
    rfidTagUid: rfidTagUid,
    rfidTagCycle: rfidTagCycle,
    createdNewCycle: createdNewCycle,
    requiresReplacement: requiresReplacement,
    syncPending: true,
  );
}

/// Optional final reconciliation after NFC audit records have been committed.
/// Inventory saving happens first because it supplies the roll/cycle identity.
abstract interface class MobileInventoryAuditSync {
  Future<void> synchronizeAuditRecords();
}

abstract interface class MobileInventorySync {
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  });
}

class NoopMobileInventorySync implements MobileInventorySync {
  const NoopMobileInventorySync();

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    return const MobileInventorySaveResult(inventoryUid: '');
  }
}
