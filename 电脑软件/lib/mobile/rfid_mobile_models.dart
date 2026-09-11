import 'package:flutter/material.dart';

import '../core/constants/personal_spool_policy.dart';
import '../core/utils/color_utils.dart';

/// The only fields the mobile writer collects from a user.
///
/// `materialType` is intentionally absent from the mobile form. The desktop
/// inventory still receives the same value in both `model` and
/// `materialType` for schema compatibility.
class MobileConsumableDraft {
  const MobileConsumableDraft({
    required this.brand,
    required this.model,
    required this.color,
    required this.colorName,
  });

  final String brand;
  final String model;
  final Color color;
  final String colorName;

  String get colorHex => ColorUtils.toHex(color);

  Map<String, dynamic> toInventoryJson({
    required String uid,
    required DateTime now,
    String? trayUuid,
    int? rfidSyncedAt,
  }) {
    final timestamp = now.toUtc().toIso8601String();
    return {
      'uid': uid,
      'manufacturer': brand,
      'model': model,
      'materialType': model,
      'colorHex': colorHex,
      if (colorName.trim().isNotEmpty) 'colorName': colorName.trim(),
      'totalGrams': personalSpoolCapacityGrams,
      'remainingGrams': personalSpoolCapacityGrams,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      if (trayUuid != null && trayUuid.trim().isNotEmpty)
        'trayUuid': trayUuid.trim(),
      if (rfidSyncedAt != null) 'rfidSyncedAt': rfidSyncedAt,
    };
  }
}

/// A small, UI-safe event set from the native NFC bridge. Raw MIFARE blocks,
/// keys and signatures never cross into Dart or the account sync API.
enum RfidSessionStatus {
  idle,
  checking,
  waiting,
  tagDetected,
  authorizedTemplateRequired,
  unsupportedTag,
  writing,
  verifying,
  success,
  cancelled,
  failed,
}

class RfidSessionEvent {
  const RfidSessionEvent({
    required this.status,
    this.message,
    this.tagType,
    this.uid,
  });

  final RfidSessionStatus status;
  final String? message;
  final String? tagType;
  final String? uid;

  factory RfidSessionEvent.fromMap(Map<dynamic, dynamic> map) {
    final rawStatus = map['status']?.toString() ?? 'failed';
    final status = RfidSessionStatus.values.firstWhere(
      (candidate) => candidate.name == rawStatus,
      orElse: () => RfidSessionStatus.failed,
    );
    return RfidSessionEvent(
      status: status,
      message: map['message']?.toString(),
      tagType: map['tagType']?.toString(),
      uid: map['uid']?.toString(),
    );
  }
}
