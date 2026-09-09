import 'dart:typed_data';

enum StudioMemberRole {
  owner,
  admin,
  operator;

  static StudioMemberRole fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? operator;
}

enum StudioOrderStatus {
  draft,
  confirmed,
  production,
  completed,
  delivered,
  cancelled;

  static StudioOrderStatus fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? draft;
}

enum StudioWorkOrderStatus {
  queued,
  assigned,
  printing,
  paused,
  completed,
  failed,
  cancelled;

  static StudioWorkOrderStatus fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? queued;
}

enum StudioWorkOrderMaterialStatus {
  unallocated,
  reserved,
  settled,
  released;

  static StudioWorkOrderMaterialStatus fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? unallocated;
}

enum StudioPrintAttemptOutcome {
  completed,
  failed,
  stopped,
  qualityRejected,
  accountingReview;

  static StudioPrintAttemptOutcome fromCode(String value) => switch (value) {
        'quality_rejected' => qualityRejected,
        'accounting_review' => accountingReview,
        _ => values.where((item) => item.name == value).firstOrNull ?? failed,
      };

  String get code => switch (this) {
        qualityRejected => 'quality_rejected',
        accountingReview => 'accounting_review',
        _ => name,
      };
}

enum StudioPlateSliceStatus {
  pending,
  slicing,
  sliced,
  failed;

  static StudioPlateSliceStatus fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? pending;
}

enum StudioQuoteStatus {
  draft,
  sent,
  accepted,
  rejected,
  expired;

  static StudioQuoteStatus fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? draft;
}

enum StudioInventoryEventType {
  receive,
  adjustment,
  reserve,
  consume,
  returnToStock;

  static StudioInventoryEventType fromCode(String value) =>
      values.where((item) => item.name == value).firstOrNull ?? adjustment;
}

class StudioWorkspace {
  const StudioWorkspace({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.remoteId,
  });

  final String id;
  final String name;
  final String? remoteId;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class StudioMember {
  const StudioMember({
    required this.id,
    required this.workspaceId,
    required this.displayName,
    required this.role,
    required this.active,
    required this.createdAt,
    this.email,
    this.loginName,
    this.employeeNo,
    this.phone,
    this.recoveryEmail,
    this.accountStatus = 'active',
    this.primaryRoleCode = 'member',
    this.roleCodes = const [],
    this.mustChangePassword = false,
    this.lastLoginAt,
    this.deactivatedAt,
  });

  final String id;
  final String workspaceId;
  final String displayName;
  final String? email;
  final String? loginName;
  final String? employeeNo;
  final String? phone;
  final String? recoveryEmail;
  final String accountStatus;
  final String primaryRoleCode;
  final List<String> roleCodes;
  final bool mustChangePassword;
  final DateTime? lastLoginAt;
  final DateTime? deactivatedAt;
  final StudioMemberRole role;
  final bool active;
  final DateTime createdAt;
}

/// 农场业务写操作的当前操作者快照。
///
/// 姓名使用快照而不是只存成员外键，确保成员改名或停用后历史记录仍可读。
class StudioActivityActor {
  const StudioActivityActor({
    required this.displayName,
    required this.identity,
    this.memberId,
  });

  final String? memberId;
  final String displayName;
  final String identity;
}

class StudioActivityEvent {
  const StudioActivityEvent({
    required this.id,
    required this.workspaceId,
    required this.actorDisplayName,
    required this.actorIdentity,
    required this.actionCode,
    required this.entityType,
    required this.entityId,
    required this.summary,
    required this.createdAt,
    this.actorMemberId,
  });

  final String id;
  final String workspaceId;
  final String? actorMemberId;
  final String actorDisplayName;
  final String actorIdentity;
  final String actionCode;
  final String entityType;
  final String entityId;
  final String summary;
  final DateTime createdAt;
}

class StudioCustomer {
  const StudioCustomer({
    required this.id,
    required this.workspaceId,
    required this.name,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
    this.contactName,
    this.phone,
    this.email,
    this.note,
  });

  final String id;
  final String workspaceId;
  final String name;
  final String? contactName;
  final String? phone;
  final String? email;
  final String? note;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class StudioOrder {
  const StudioOrder({
    required this.id,
    required this.workspaceId,
    required this.orderNo,
    required this.title,
    required this.status,
    required this.totalPrice,
    required this.createdAt,
    required this.updatedAt,
    this.customerId,
    this.dueAt,
    this.note,
    this.publicNote,
    this.portalVideoEnabled = true,
  });

  final String id;
  final String workspaceId;
  final String? customerId;
  final String orderNo;
  final String title;
  final StudioOrderStatus status;
  final DateTime? dueAt;
  final double totalPrice;
  final String? note;
  final String? publicNote;
  final bool portalVideoEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class StudioWorkOrder {
  const StudioWorkOrder({
    required this.id,
    required this.workspaceId,
    required this.orderId,
    required this.title,
    required this.quantity,
    required this.completedQuantity,
    required this.status,
    required this.materialCostSnapshot,
    required this.quotedPriceSnapshot,
    required this.createdAt,
    required this.updatedAt,
    this.schedulerTaskId,
    this.productionPlateId,
    this.assignedMemberId,
    this.printerId,
    this.estimatedSeconds,
    this.note,
  });

  final String id;
  final String workspaceId;
  final String orderId;
  final int? schedulerTaskId;
  final String? productionPlateId;
  final String title;
  final int quantity;
  final int completedQuantity;
  final StudioWorkOrderStatus status;
  final String? assignedMemberId;
  final int? printerId;
  final int? estimatedSeconds;
  final double materialCostSnapshot;
  final double quotedPriceSnapshot;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get completion =>
      quantity <= 0 ? 0 : (completedQuantity / quantity).clamp(0.0, 1.0);
}

/// Per-tool material ledger for one independently scheduled farm work order.
///
/// [estimatedGrams] already includes the work order quantity. A plate split
/// across two printers therefore owns two independent reservations instead of
/// reserving the complete customer order twice.
class StudioWorkOrderMaterial {
  const StudioWorkOrderMaterial({
    required this.id,
    required this.workspaceId,
    required this.workOrderId,
    required this.productionPlateId,
    required this.toolIndex,
    required this.estimatedGrams,
    required this.reservedGrams,
    required this.consumedGrams,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.materialType,
    this.colorHex,
    this.sku,
    this.consumableId,
    this.printerChannelId,
    this.settledAt,
  });

  final String id;
  final String workspaceId;
  final String workOrderId;
  final String productionPlateId;
  final int toolIndex;
  final String? materialType;
  final String? colorHex;
  final String? sku;
  final double estimatedGrams;
  final int? consumableId;
  final int? printerChannelId;
  final double reservedGrams;
  final double consumedGrams;
  final StudioWorkOrderMaterialStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? settledAt;

  bool get isAllocated =>
      consumableId != null && status == StudioWorkOrderMaterialStatus.reserved;

  bool get isSettled => status == StudioWorkOrderMaterialStatus.settled;
}

class StudioPrintAttempt {
  const StudioPrintAttempt({
    required this.id,
    required this.workspaceId,
    required this.workOrderId,
    required this.attemptNo,
    required this.outcome,
    required this.consumedGrams,
    required this.materialCost,
    required this.endedAt,
    required this.createdAt,
    required this.updatedAt,
    this.printQueueId,
    this.printerSerial,
    this.progressPercent,
    this.failureReason,
    this.errorCode,
    this.startedAt,
  });

  final String id;
  final String workspaceId;
  final String workOrderId;
  final int? printQueueId;
  final int attemptNo;
  final String? printerSerial;
  final StudioPrintAttemptOutcome outcome;
  final int? progressPercent;
  final double consumedGrams;
  final double materialCost;
  final String? failureReason;
  final String? errorCode;
  final DateTime? startedAt;
  final DateTime endedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get needsAccountingReview =>
      outcome == StudioPrintAttemptOutcome.accountingReview;

  bool get isWaste =>
      outcome == StudioPrintAttemptOutcome.failed ||
      outcome == StudioPrintAttemptOutcome.stopped ||
      outcome == StudioPrintAttemptOutcome.qualityRejected;
}

class StudioConsumableAvailability {
  const StudioConsumableAvailability({
    required this.remainingGrams,
    required this.schedulerReservedGrams,
    required this.printTaskReservedGrams,
    required this.studioReservedGrams,
  });

  final double remainingGrams;
  final double schedulerReservedGrams;
  final double printTaskReservedGrams;
  final double studioReservedGrams;

  double get totalReservedGrams =>
      schedulerReservedGrams + printTaskReservedGrams + studioReservedGrams;

  double get availableGrams => (remainingGrams - totalReservedGrams)
      .clamp(0.0, double.infinity)
      .toDouble();
}

class StudioProductionPackage {
  const StudioProductionPackage({
    required this.id,
    required this.workspaceId,
    required this.orderId,
    required this.sourceName,
    required this.artifactKind,
    required this.createdAt,
    this.localPath,
    this.artifactSha256,
    this.slicerName,
    this.slicerVersion,
    this.targetModel,
    this.nozzleDiameter,
  });

  final String id;
  final String workspaceId;
  final String orderId;
  final String sourceName;
  final String? localPath;
  final String? artifactSha256;
  final String artifactKind;
  final String? slicerName;
  final String? slicerVersion;
  final String? targetModel;
  final double? nozzleDiameter;
  final DateTime createdAt;
}

class StudioProductionPlate {
  const StudioProductionPlate({
    required this.id,
    required this.workspaceId,
    required this.orderId,
    required this.packageId,
    required this.plateIndex,
    required this.name,
    required this.requiredRuns,
    required this.estimatedSeconds,
    required this.estimatedGrams,
    required this.createdAt,
    DateTime? updatedAt,
    this.sliceStatus = StudioPlateSliceStatus.pending,
    this.totalLayers = 0,
    this.toolChangeCount = 0,
    this.filaments = const [],
    this.sliceArtifactPath,
    this.sliceArtifactSha256,
    this.sliceTargetModel,
    this.sliceNozzleDiameter,
    this.autoEjectEnabled,
    this.thumbnailBytes,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String workspaceId;
  final String orderId;
  final String packageId;
  final int plateIndex;
  final String name;
  final int requiredRuns;
  final int estimatedSeconds;
  final double estimatedGrams;
  final StudioPlateSliceStatus sliceStatus;
  final int totalLayers;
  final int toolChangeCount;
  final List<StudioPlateFilamentUsage> filaments;
  final String? sliceArtifactPath;
  final String? sliceArtifactSha256;
  final String? sliceTargetModel;
  final double? sliceNozzleDiameter;

  /// Whether the stored slice artifact contains an automatic-ejection block.
  /// NULL means the artifact predates this metadata or came from an unknown
  /// external source and must not be reused without rebuilding it.
  final bool? autoEjectEnabled;
  final Uint8List? thumbnailBytes;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isSliced => sliceStatus == StudioPlateSliceStatus.sliced;

  List<StudioPlateFilamentUsage> get activeFilaments =>
      StudioPlateFilamentUsage.activeByTool(filaments);

  bool get isMulticolor => activeFilaments.length > 1;

  double get totalRequiredGrams => estimatedGrams * requiredRuns;
}

class StudioPlateFilamentUsage {
  const StudioPlateFilamentUsage({
    required this.toolIndex,
    required this.grams,
    this.vendor,
    this.materialType,
    this.colorHex,
    this.trayId,
    this.sku,
    this.usedForObject,
    this.usedForSupport,
    this.groupId,
    this.nozzleDiameter,
    this.volumeType,
  });

  final int toolIndex;
  final double grams;
  final String? vendor;
  final String? materialType;
  final String? colorHex;
  final int? trayId;
  final String? sku;
  final bool? usedForObject;
  final bool? usedForSupport;
  final int? groupId;
  final double? nozzleDiameter;
  final String? volumeType;

  bool get isActive => grams > 0.01;

  StudioPlateFilamentUsage mergeUsage(StudioPlateFilamentUsage other) =>
      StudioPlateFilamentUsage(
        toolIndex: toolIndex,
        grams: grams + other.grams,
        vendor: vendor ?? other.vendor,
        materialType: materialType ?? other.materialType,
        colorHex: colorHex ?? other.colorHex,
        trayId: trayId ?? other.trayId,
        sku: sku ?? other.sku,
        usedForObject: _mergeUsageFlag(usedForObject, other.usedForObject),
        usedForSupport: _mergeUsageFlag(usedForSupport, other.usedForSupport),
        groupId: groupId ?? other.groupId,
        nozzleDiameter: nozzleDiameter ?? other.nozzleDiameter,
        volumeType: volumeType ?? other.volumeType,
      );

  static List<StudioPlateFilamentUsage> activeByTool(
    Iterable<StudioPlateFilamentUsage> values,
  ) {
    final byTool = <int, StudioPlateFilamentUsage>{};
    for (final item in values.where((item) => item.isActive)) {
      final existing = byTool[item.toolIndex];
      byTool[item.toolIndex] =
          existing == null ? item : existing.mergeUsage(item);
    }
    final result = byTool.values.toList()
      ..sort((a, b) => a.toolIndex.compareTo(b.toolIndex));
    return result;
  }
}

bool? _mergeUsageFlag(bool? first, bool? second) {
  if (first == true || second == true) return true;
  if (first == false && second == false) return false;
  return first ?? second;
}

class StudioOrderItem {
  const StudioOrderItem({
    required this.id,
    required this.workspaceId,
    required this.orderId,
    required this.packageId,
    required this.plateId,
    required this.sourceKey,
    required this.name,
    required this.perRunQuantity,
    required this.requiredQuantity,
    required this.createdAt,
  });

  final String id;
  final String workspaceId;
  final String orderId;
  final String packageId;
  final String plateId;
  final String sourceKey;
  final String name;
  final int perRunQuantity;
  final int requiredQuantity;
  final DateTime createdAt;
}

class StudioProductionPackageDraft {
  const StudioProductionPackageDraft({
    required this.sourceName,
    required this.artifactKind,
    required this.plates,
    this.localPath,
    this.artifactSha256,
    this.slicerName,
    this.slicerVersion,
    this.targetModel,
    this.nozzleDiameter,
  });

  final String sourceName;
  final String? localPath;
  final String? artifactSha256;
  final String artifactKind;
  final String? slicerName;
  final String? slicerVersion;
  final String? targetModel;
  final double? nozzleDiameter;
  final List<StudioProductionPlateDraft> plates;
}

class StudioProductionPlateDraft {
  const StudioProductionPlateDraft({
    required this.plateIndex,
    required this.name,
    required this.requiredRuns,
    required this.estimatedSeconds,
    required this.estimatedGrams,
    required this.items,
    this.assignedPrinterIds = const [],
    this.sliceStatus = StudioPlateSliceStatus.pending,
    this.totalLayers = 0,
    this.toolChangeCount = 0,
    this.filaments = const [],
    this.sliceArtifactPath,
    this.sliceArtifactSha256,
    this.sliceTargetModel,
    this.sliceNozzleDiameter,
    this.autoEjectEnabled,
    this.thumbnailBytes,
  });

  final int plateIndex;
  final String name;
  final int requiredRuns;
  final int estimatedSeconds;
  final double estimatedGrams;
  final StudioPlateSliceStatus sliceStatus;
  final int totalLayers;
  final int toolChangeCount;
  final List<StudioPlateFilamentUsage> filaments;
  final String? sliceArtifactPath;
  final String? sliceArtifactSha256;
  final String? sliceTargetModel;
  final double? sliceNozzleDiameter;
  final bool? autoEjectEnabled;
  final Uint8List? thumbnailBytes;
  final List<int> assignedPrinterIds;
  final List<StudioOrderItemDraft> items;

  List<StudioPlateFilamentUsage> get activeFilaments =>
      StudioPlateFilamentUsage.activeByTool(filaments);

  bool get isMulticolor => activeFilaments.length > 1;

  double get totalRequiredGrams => estimatedGrams * requiredRuns;
}

class StudioOrderItemDraft {
  const StudioOrderItemDraft({
    required this.sourceKey,
    required this.name,
    required this.perRunQuantity,
    required this.requiredQuantity,
  });

  final String sourceKey;
  final String name;
  final int perRunQuantity;
  final int requiredQuantity;
}

class StudioQuote {
  const StudioQuote({
    required this.id,
    required this.workspaceId,
    required this.quoteNo,
    required this.title,
    required this.status,
    required this.materialLabel,
    required this.estimatedGrams,
    required this.materialCostPerKgSnapshot,
    required this.machineHours,
    required this.machineRatePerHour,
    required this.laborHours,
    required this.laborRatePerHour,
    required this.electricityCost,
    required this.packagingCost,
    required this.riskPercent,
    required this.markupPercent,
    required this.totalCost,
    required this.quotedPrice,
    required this.createdAt,
    required this.updatedAt,
    this.customerId,
    this.orderId,
    this.costConfigId,
    this.note,
  });

  final String id;
  final String workspaceId;
  final String? customerId;
  final String? orderId;
  final int? costConfigId;
  final String quoteNo;
  final String title;
  final StudioQuoteStatus status;
  final String materialLabel;
  final double estimatedGrams;
  final double materialCostPerKgSnapshot;
  final double machineHours;
  final double machineRatePerHour;
  final double laborHours;
  final double laborRatePerHour;
  final double electricityCost;
  final double packagingCost;
  final double riskPercent;
  final double markupPercent;
  final double totalCost;
  final double quotedPrice;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  double get profit => quotedPrice - totalCost;
}

class StudioInventoryEvent {
  const StudioInventoryEvent({
    required this.id,
    required this.workspaceId,
    required this.consumableId,
    required this.type,
    required this.deltaGrams,
    required this.reason,
    required this.createdAt,
    this.memberId,
  });

  final String id;
  final String workspaceId;
  final int consumableId;
  final StudioInventoryEventType type;
  final double deltaGrams;
  final String reason;
  final String? memberId;
  final DateTime createdAt;
}

class StudioInventoryBatch {
  const StudioInventoryBatch({
    required this.id,
    required this.workspaceId,
    required this.batchNo,
    required this.receivedAt,
    required this.rollCount,
    required this.totalGrams,
    required this.createdAt,
    DateTime? updatedAt,
    this.supplier,
    this.note,
    this.memberId,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String workspaceId;
  final String batchNo;
  final String? supplier;
  final DateTime receivedAt;
  final int rollCount;
  final double totalGrams;
  final String? note;
  final String? memberId;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class StudioInventoryBatchItem {
  const StudioInventoryBatchItem({
    required this.id,
    required this.batchId,
    required this.consumableId,
    required this.rollCount,
    required this.gramsPerRoll,
    required this.unitCost,
    required this.createdAt,
    DateTime? updatedAt,
    this.voided = false,
    this.voidReason,
    this.voidedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String batchId;
  final int consumableId;
  final int rollCount;
  final double gramsPerRoll;
  final double unitCost;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool voided;
  final String? voidReason;
  final DateTime? voidedAt;
}

class StudioBatchReceiveLine {
  const StudioBatchReceiveLine({
    required this.manufacturer,
    required this.materialType,
    required this.colorHex,
    required this.rolls,
    this.model,
    this.brandCode,
    this.colorName,
    this.colorMode = 'solid',
    this.secondaryColorHex,
    this.gramsPerRoll = 1000,
    this.unitCost = 0,
  });

  final String manufacturer;
  final String? brandCode;
  final String? model;
  final String materialType;
  final String colorHex;
  final String? colorName;
  final String colorMode;
  final String? secondaryColorHex;
  final int rolls;
  final double gramsPerRoll;
  final double unitCost;
}

class StudioShareLink {
  const StudioShareLink({
    required this.id,
    required this.workspaceId,
    required this.orderId,
    required this.tokenPreview,
    required this.active,
    required this.createdAt,
    this.publicUrl,
    this.expiresAt,
    this.passwordRequired = true,
  });

  final String id;
  final String workspaceId;
  final String orderId;
  final String tokenPreview;
  final String? publicUrl;
  final bool active;
  final DateTime? expiresAt;
  final bool passwordRequired;
  final DateTime createdAt;
}

class StudioSnapshot {
  const StudioSnapshot({
    required this.workspace,
    required this.members,
    required this.customers,
    required this.orders,
    required this.workOrders,
    required this.quotes,
    required this.inventoryEvents,
    required this.inventoryBatches,
    required this.shareLinks,
    this.inventoryBatchItems = const [],
    this.productionPackages = const [],
    this.productionPlates = const [],
    this.orderItems = const [],
    this.workOrderMaterials = const [],
    this.printAttempts = const [],
    this.activityEvents = const [],
  });

  final StudioWorkspace workspace;
  final List<StudioMember> members;
  final List<StudioCustomer> customers;
  final List<StudioOrder> orders;
  final List<StudioWorkOrder> workOrders;
  final List<StudioQuote> quotes;
  final List<StudioInventoryEvent> inventoryEvents;
  final List<StudioInventoryBatch> inventoryBatches;
  final List<StudioInventoryBatchItem> inventoryBatchItems;
  final List<StudioShareLink> shareLinks;
  final List<StudioProductionPackage> productionPackages;
  final List<StudioProductionPlate> productionPlates;
  final List<StudioOrderItem> orderItems;
  final List<StudioWorkOrderMaterial> workOrderMaterials;
  final List<StudioPrintAttempt> printAttempts;
  final List<StudioActivityEvent> activityEvents;

  StudioActivityEvent? latestActivityFor(String entityType, String entityId) {
    for (final event in activityEvents) {
      if (event.entityType == entityType && event.entityId == entityId) {
        return event;
      }
    }
    return null;
  }

  int get activeOrderCount => orders
      .where(
        (order) =>
            order.status != StudioOrderStatus.completed &&
            order.status != StudioOrderStatus.delivered &&
            order.status != StudioOrderStatus.cancelled,
      )
      .length;

  double get batchCompletionRate {
    final total = workOrders.fold<int>(0, (sum, item) => sum + item.quantity);
    if (total == 0) return 0;
    final completed = workOrders.fold<int>(
      0,
      (sum, item) => sum + item.completedQuantity,
    );
    return (completed / total).clamp(0.0, 1.0);
  }

  double get acceptedRevenue => quotes
      .where((quote) => quote.status == StudioQuoteStatus.accepted)
      .fold(0, (sum, quote) => sum + quote.quotedPrice);

  double get acceptedProfit => quotes
      .where((quote) => quote.status == StudioQuoteStatus.accepted)
      .fold(0, (sum, quote) => sum + quote.profit);
}
