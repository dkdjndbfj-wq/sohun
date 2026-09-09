import 'dart:async';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../../core/services/printer_model_normalizer.dart';
import '../../external/printer/bambu_cloud_models.dart';
import '../../external/printer/bambu_printer_models.dart';
import '../../models/rfid_tag_identity.dart';
import '../../seed/printer_seed.dart';
import '../database.dart';
import '../personal_spool_handoff.dart';
import '../personal_ams_identity.dart';
import '../models/printer_feed_models.dart';
import '../tables.dart';
import 'consumable_dao.dart';

part 'printer_dao.g.dart';

/// 打印机 + 通道（含绑定的耗材）组合视图，供 UI 直接渲染。
class PrinterWithChannels {
  final Printer printer;
  final List<ChannelWithConsumable> channels;

  /// 打印机序列号（来自云端同步，raw SQL 列，drift 代码生成不含此字段）。
  /// 非 null 表示该打印机是从云端录入的，可和云端设备列表/活跃打印机匹配。
  final String? serial;

  PrinterWithChannels(this.printer, this.channels, {this.serial});
}

/// Local-only hold state for a printer feed. This integer is stored in the
/// historical `farm_roll_paused` column, but is deliberately not part of the
/// personal-inventory sync payload.
enum ChannelRollHoldState {
  loaded(0),
  maintenance(1),
  awaitingSelection(2);

  const ChannelRollHoldState(this.dbValue);

  final int dbValue;

  static ChannelRollHoldState fromDb(int? value) => switch (value) {
    1 => maintenance,
    2 => awaitingSelection,
    _ => loaded,
  };

  bool get isHeld => this != loaded;
}

class ChannelWithConsumable {
  final PrinterChannel channel;
  final Consumable? consumable;
  final ChannelRollHoldState rollHoldState;

  ChannelWithConsumable(
    this.channel,
    this.consumable, {
    bool farmRollPaused = false,
    ChannelRollHoldState? rollHoldState,
  }) : rollHoldState =
           rollHoldState ??
           (farmRollPaused
               ? ChannelRollHoldState.maintenance
               : ChannelRollHoldState.loaded);

  bool get farmRollPaused => rollHoldState.isHeld;
  bool get awaitingSpoolSelection =>
      rollHoldState == ChannelRollHoldState.awaitingSelection;

  bool get isActive =>
      consumable != null && channel.loadedRemainingGrams > 0 && !farmRollPaused;
}

enum FarmRollLoadAuthorization { none, farmOwnerConfirmed, rfidDetected }

/// 打印机数据访问层。管理打印机及其多色通道。
@DriftAccessor(tables: [Printers, PrinterChannels, Consumables, UsageLogs])
class PrinterDao extends DatabaseAccessor<AppDatabase> with _$PrinterDaoMixin {
  PrinterDao(super.db);

  static const _uuid = Uuid();
  static const double _farmRollGrams = 1000;

  /// 耗材 DAO 引用（用于拓竹原厂料自动绑定和 RFID 残量同步）。
  late final ConsumableDao _consumableDao = ConsumableDao(attachedDatabase);

  /// 监听所有打印机 + 通道 + 耗材变化。
  /// 用 StreamController 手动合并三表 watch，任一表变化就全量重查。
  /// dirty 标记确保加载期间的新事件不会被吞掉。
  Stream<List<PrinterWithChannels>> watchAllWithChannels() {
    late StreamController<List<PrinterWithChannels>> controller;
    StreamSubscription? sub1, sub2, sub3;
    bool loading = false;
    bool dirty = false;

    Future<void> reload() async {
      if (loading) {
        dirty = true;
        return;
      }
      loading = true;
      try {
        do {
          dirty = false;
          final data = await _fetchAllWithChannels();
          if (!controller.isClosed) controller.add(data);
        } while (dirty);
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      } finally {
        loading = false;
      }
    }

    controller = StreamController<List<PrinterWithChannels>>(
      onListen: () {
        sub1 = select(printers).watch().listen((_) => reload());
        sub2 = select(printerChannels).watch().listen((_) => reload());
        sub3 = select(consumables).watch().listen((_) => reload());
        reload();
      },
      onCancel: () {
        sub1?.cancel();
        sub2?.cancel();
        sub3?.cancel();
        controller.close();
      },
    );
    return controller.stream;
  }

  /// 监听单台打印机详情，通道/耗材变化时自动刷新。
  Stream<PrinterWithChannels?> watchByIdWithChannels(int id) {
    late StreamController<PrinterWithChannels?> controller;
    StreamSubscription? sub1, sub2, sub3;
    bool loading = false;
    bool dirty = false;

    Future<void> reload() async {
      if (loading) {
        dirty = true;
        return;
      }
      loading = true;
      try {
        do {
          dirty = false;
          final data = await _fetchByIdWithChannels(id);
          if (!controller.isClosed) controller.add(data);
        } while (dirty);
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      } finally {
        loading = false;
      }
    }

    controller = StreamController<PrinterWithChannels?>(
      onListen: () {
        sub1 = (select(
          printers,
        )..where((t) => t.id.equals(id))).watch().listen((_) => reload());
        sub2 = (select(printerChannels)..where((t) => t.printerId.equals(id)))
            .watch()
            .listen((_) => reload());
        sub3 = select(consumables).watch().listen((_) => reload());
        reload();
      },
      onCancel: () {
        sub1?.cancel();
        sub2?.cancel();
        sub3?.cancel();
        controller.close();
      },
    );
    return controller.stream;
  }

  Future<List<PrinterWithChannels>> _fetchAllWithChannels() async {
    final printerList =
        await (select(printers)..orderBy([
              (t) => OrderingTerm(
                expression: t.channelCount,
                mode: OrderingMode.asc,
              ),
              (t) => OrderingTerm(
                expression: t.createdAt,
                mode: OrderingMode.desc,
              ),
            ]))
            .get();
    // serial 列不在 drift 表定义中，用 raw SQL 一次性查出所有打印机的 serial
    final serialMap = await _loadSerialMap();
    // P0-2 修复：一次性 JOIN 查询所有打印机的通道+耗材，替代 N+1 循环。
    // 旧实现：每台打印机调用一次 _loadChannels，每个通道再调用一次 getById，
    // 总查询数 = printerCount × (1 + channelCount)，多打印机场景下严重放大。
    final channelsMap = await _loadAllChannelsGrouped();
    return printerList
        .map(
          (p) => PrinterWithChannels(
            p,
            channelsMap[p.id] ?? const <ChannelWithConsumable>[],
            serial: serialMap[p.id],
          ),
        )
        .toList();
  }

  Future<PrinterWithChannels?> _fetchByIdWithChannels(int id) async {
    final p = await (select(
      printers,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (p == null) return null;
    final serialMap = await _loadSerialMap();
    // P0-2 修复：单台打印机也用 JOIN，避免每个通道单独查询耗材。
    final channels = await _loadChannelsForPrinter(id);
    return PrinterWithChannels(p, channels, serial: serialMap[id]);
  }

  /// 查询所有打印机的 serial（raw SQL，因 serial 列不在 drift 代码生成范围）。
  /// 返回 Map<printerId, serial>，serial 为 null 表示该打印机非云端同步。
  Future<Map<int, String?>> _loadSerialMap() async {
    final rows = await customSelect('SELECT id, serial FROM printers').get();
    final map = <int, String?>{};
    for (final row in rows) {
      map[row.read<int>('id')] = row.read<String?>('serial');
    }
    return map;
  }

  Future<PrinterWithChannels?> getByIdWithChannels(int id) =>
      _fetchByIdWithChannels(id);

  /// 一次性获取所有打印机 + 通道 + 耗材（非 watch 版）。
  /// 供调度器等不需要实时订阅的场景使用，避免 Stream 订阅开销。
  Future<List<PrinterWithChannels>> getAllPrintersWithChannels() =>
      _fetchAllWithChannels();

  /// 轻量单条查询，只取打印机本身（不加载通道），用于日志卡片显示名称。
  Future<Printer?> getById(int id) {
    return (select(printers)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 按 serial 查询打印机 id（raw SQL，因 serial 列不在 drift 代码生成范围）。
  /// 用于把活跃打印机的 serial 映射到本地 printers.id，
  /// 例如「打印机屏幕启动任务自动创建」时需要关联本地 printer_id。
  Future<int?> getPrinterIdBySerial(String serial) async {
    final rows = await customSelect(
      'SELECT id FROM printers WHERE serial = ?',
      variables: [Variable(serial)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.read<int>('id');
  }

  /// 查询指定打印机 + 通道当前绑定的耗材 id（raw SQL）。
  /// 用于 AMS 换料事件记录时关联通道耗材。
  /// 返回 null 表示该通道未绑定耗材或通道不存在。
  Future<int?> getConsumableIdByChannel(int printerId, int channelIndex) async {
    final rows = await customSelect(
      'SELECT consumable_id FROM printer_channels '
      'WHERE printer_id = ? AND channel_index = ? '
      'ORDER BY id DESC LIMIT 1',
      variables: [Variable(printerId), Variable(channelIndex)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.read<int?>('consumable_id');
  }

  /// Binds a confirmed physical spool replacement to a channel.
  ///
  /// AMS telemetry can create sparse global slots (for example AMS HT starts
  /// at slot 16), so the channel row is created on demand before applying the
  /// normal change-roll transaction.
  Future<void> bindSpoolReplacement({
    required int printerId,
    required int channelIndex,
    required int consumableId,
    double? manualRemainingGrams,
    bool uniquePhysicalSpool = false,
    bool farmOwnerConfirmed = false,
    String? confirmedAmsUid,
    String? sourceTagUid,
    String? sourceTagType,
    String? sourceOwnerAccount,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    if (channelIndex < 0) return;
    return transaction(() async {
      final existingChannel = await customSelect(
        'SELECT id FROM printer_channels '
        'WHERE printer_id = ? AND channel_index = ? LIMIT 1',
        variables: [Variable(printerId), Variable(channelIndex)],
      ).getSingleOrNull();
      if (existingChannel != null) {
        await _assertChannelPersonalOwnerAccess(
          existingChannel.read<int>('id'),
          enforce: enforcePersonalOwner,
          ownerAccount: personalOwnerAccount,
        );
      }
      await _assertConsumablePersonalOwnerAccess(
        consumableId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final sourceValues = [sourceTagUid, sourceTagType, sourceOwnerAccount];
      final sourceValueCount = sourceValues
          .where((value) => value != null)
          .length;
      if (sourceValueCount != 0 && sourceValueCount != sourceValues.length) {
        throw ArgumentError('资料卡库存候选缺少标签类型或账号归属');
      }
      if (sourceTagUid != null) {
        if (confirmedAmsUid == null) {
          throw ArgumentError('资料卡选卷必须同时确认 AMS 上报的完整标识');
        }
        final currentHistory = await _consumableDao.getPersonalRfidSpoolHistory(
          sourceTagUid,
          ownerAccount: sourceOwnerAccount!.isEmpty ? null : sourceOwnerAccount,
        );
        final active = currentHistory.where((entry) => entry.isActive).toList();
        var continueCurrentTask = false;
        // “准备换卷”会先把槽内旧 CUID/FUID 卷标为 replaced，同时保留
        // paused channel 与未结算任务。这里仍要把该最新周期视为任务交接源。
        final handoffSource = active.length == 1
            ? active.single
            : active.isEmpty && currentHistory.isNotEmpty
            ? currentHistory.first
            : null;
        if (handoffSource != null) {
          final activeChannels = await customSelect(
            'SELECT printer_id, channel_index FROM printer_channels '
            'WHERE consumable_id = ?',
            variables: [Variable(handoffSource.consumableId)],
          ).get();
          continueCurrentTask =
              activeChannels.length == 1 &&
              activeChannels.single.read<int>('printer_id') == printerId &&
              activeChannels.single.read<int>('channel_index') == channelIndex;
        }
        await _consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: consumableId,
          tagUid: sourceTagUid,
          tagType: sourceTagType!,
          ownerAccount: sourceOwnerAccount.isEmpty ? null : sourceOwnerAccount,
          continueCurrentTask: continueCurrentTask,
        );
      }
      if (confirmedAmsUid != null) {
        await confirmPersonalAmsIdentity(
          attachedDatabase,
          consumableId: consumableId,
          reportedUid: confirmedAmsUid,
        );
      }
      if (uniquePhysicalSpool) {
        if (!await _consumableDao.isFarmConsumable(consumableId)) {
          await PersonalSpoolHandoff(
            attachedDatabase,
          ).assertNotReservedElsewhere(consumableId, printerId, channelIndex);
        }
        await customUpdate(
          'UPDATE printer_channels SET consumable_id = NULL, '
          'loaded_remaining_grams = 0, loaded_spool_uid = NULL, '
          'farm_roll_paused = 0, updated_at = ? '
          'WHERE consumable_id = ? '
          'AND NOT (printer_id = ? AND channel_index = ?)',
          variables: [
            // printer_channels.updated_at is a Drift DateTime column. Drift's
            // SQLite representation is Unix seconds (not milliseconds).
            Variable<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000),
            Variable<int>(consumableId),
            Variable<int>(printerId),
            Variable<int>(channelIndex),
          ],
          updates: {printerChannels},
        );
      }
      var rows = await customSelect(
        'SELECT id FROM printer_channels '
        'WHERE printer_id = ? AND channel_index = ? LIMIT 1',
        variables: [Variable(printerId), Variable(channelIndex)],
      ).get();
      if (rows.isEmpty) {
        final channelId = await into(printerChannels).insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: channelIndex,
            label: Value(_channelLabel(channelIndex)),
          ),
        );
        await changeRoll(
          channelId: channelId,
          newConsumableId: consumableId,
          manualRemainingGrams: manualRemainingGrams,
          farmLoadAuthorization: uniquePhysicalSpool
              ? FarmRollLoadAuthorization.rfidDetected
              : farmOwnerConfirmed
              ? FarmRollLoadAuthorization.farmOwnerConfirmed
              : FarmRollLoadAuthorization.none,
          enforcePersonalOwner: enforcePersonalOwner,
          personalOwnerAccount: personalOwnerAccount,
        );
        await _refreshChannelCount(printerId);
        return;
      }
      await changeRoll(
        channelId: rows.first.read<int>('id'),
        newConsumableId: consumableId,
        manualRemainingGrams: manualRemainingGrams,
        farmLoadAuthorization: uniquePhysicalSpool
            ? FarmRollLoadAuthorization.rfidDetected
            : farmOwnerConfirmed
            ? FarmRollLoadAuthorization.farmOwnerConfirmed
            : FarmRollLoadAuthorization.none,
        enforcePersonalOwner: enforcePersonalOwner,
        personalOwnerAccount: personalOwnerAccount,
      );
    });
  }

  String _channelLabel(int index) {
    if (index == externalFeedRightChannel) return '外挂料位 R';
    if (index == externalFeedLeftChannel) return '外挂料位 L';
    final group = index ~/ 4;
    final slot = index % 4;
    final letter = String.fromCharCode(65 + slot);
    return group == 0 ? letter : '${group + 1}$letter';
  }

  String _amsChannelLabel(
    AmsTray tray,
    ({int ordinal, AmsUnitType type})? fact,
  ) {
    final ordinal = fact?.ordinal ?? (tray.amsId >= 128 ? 1 : tray.amsId + 1);
    final type = fact?.type.displayLabel ?? 'AMS';
    return '第 $ordinal 台 $type · 第 ${tray.slot + 1} 通道';
  }

  Future<void> _refreshChannelCount(int printerId) async {
    final count =
        await (selectOnly(printerChannels)
              ..addColumns([printerChannels.id.count()])
              ..where(printerChannels.printerId.equals(printerId)))
            .map((row) => row.read(printerChannels.id.count()) ?? 0)
            .getSingle();
    await (update(printers)..where((table) => table.id.equals(printerId)))
        .write(PrintersCompanion(channelCount: Value(count)));
  }

  /// 轻量全量查询，只取打印机本身（不加载通道）。
  Future<List<Printer>> getAllPrinters() {
    return (select(printers)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  /// 按归属账号查询打印机。
  ///
  /// 多账号场景下记录每台打印机的原始归属（email|region_code 格式），
  /// 用于设备迁移、账号维度统计等。日常列表展示仍用 [getAllPrinters] /
  /// [watchAllWithChannels]（跨账号共享所有打印机）。
  Future<List<Printer>> getByOwnerAccount(String ownerAccount) {
    return (select(printers)
          ..where((t) => t.ownerAccount.equals(ownerAccount))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  /// P0-2 修复：单台打印机的通道+耗材，2 次查询替代 N+1。
  /// 旧实现循环调用 consumableDao.getById，N 个通道 = N 次查询。
  /// 现改为：1 次查全部通道 + 1 次用 IN 批量查关联耗材。
  Future<List<ChannelWithConsumable>> _loadChannelsForPrinter(
    int printerId,
  ) async {
    final channels =
        await (select(printerChannels)
              ..where((t) => t.printerId.equals(printerId))
              ..orderBy([(t) => OrderingTerm(expression: t.channelIndex)]))
            .get();
    if (channels.isEmpty) return [];
    final consMap = await _batchLoadConsumables(channels);
    final holdStates = await _loadChannelRollHoldStates(printerId: printerId);
    return channels
        .map(
          (ch) => ChannelWithConsumable(
            ch,
            ch.consumableId == null ? null : consMap[ch.consumableId],
            rollHoldState: holdStates[ch.id] ?? ChannelRollHoldState.loaded,
          ),
        )
        .toList();
  }

  /// P0-2 修复：所有打印机的通道+耗材，2 次查询后按 printerId 分组。
  /// 替代旧实现的 N+1 循环（每台打印机一次查询 + 每个通道一次 getById）。
  Future<Map<int, List<ChannelWithConsumable>>>
  _loadAllChannelsGrouped() async {
    final allChannels =
        await (select(printerChannels)..orderBy([
              (t) => OrderingTerm(expression: t.printerId),
              (t) => OrderingTerm(expression: t.channelIndex),
            ]))
            .get();
    final consMap = await _batchLoadConsumables(allChannels);
    final holdStates = await _loadChannelRollHoldStates();
    final map = <int, List<ChannelWithConsumable>>{};
    for (final channel in allChannels) {
      final consumable = channel.consumableId == null
          ? null
          : consMap[channel.consumableId];
      map
          .putIfAbsent(channel.printerId, () => [])
          .add(
            ChannelWithConsumable(
              channel,
              consumable,
              rollHoldState:
                  holdStates[channel.id] ?? ChannelRollHoldState.loaded,
            ),
          );
    }
    return map;
  }

  /// 批量加载通道关联的耗材，返回 Map<consumableId, Consumable>。
  /// 把 N 次 getById 合并为 1 次 IN 查询。
  Future<Map<int, Consumable>> _batchLoadConsumables(
    List<PrinterChannel> channels,
  ) async {
    final ids = channels
        .map((c) => c.consumableId)
        .whereType<int>()
        .toSet()
        .toList();
    if (ids.isEmpty) return {};
    // 注意：局部变量名用 consList 避免与 drift 表 getter 'consumables' 冲突
    final consList = await (select(
      consumables,
    )..where((t) => t.id.isIn(ids))).get();
    return {for (final c in consList) c.id: c};
  }

  Future<Set<int>> _loadPausedChannelIds({int? printerId}) async {
    final rows = await customSelect(
      'SELECT id FROM printer_channels WHERE farm_roll_paused > 0 '
      '${printerId == null ? '' : 'AND printer_id = ?'}',
      variables: [if (printerId != null) Variable(printerId)],
    ).get();
    return rows.map((row) => row.read<int>('id')).toSet();
  }

  Future<Map<int, ChannelRollHoldState>> _loadChannelRollHoldStates({
    int? printerId,
  }) async {
    final rows = await customSelect(
      'SELECT id, farm_roll_paused FROM printer_channels '
      'WHERE farm_roll_paused > 0 '
      '${printerId == null ? '' : 'AND printer_id = ?'}',
      variables: [if (printerId != null) Variable(printerId)],
    ).get();
    return {
      for (final row in rows)
        row.read<int>('id'): ChannelRollHoldState.fromDb(
          row.read<int?>('farm_roll_paused'),
        ),
    };
  }

  Future<ChannelRollHoldState> getChannelRollHoldState(
    int printerId,
    int channelIndex,
  ) async {
    final row = await customSelect(
      'SELECT farm_roll_paused FROM printer_channels '
      'WHERE printer_id = ? AND channel_index = ? LIMIT 1',
      variables: [Variable(printerId), Variable(channelIndex)],
    ).getSingleOrNull();
    return ChannelRollHoldState.fromDb(row?.read<int?>('farm_roll_paused'));
  }

  Future<bool> isPersonalSpoolAwaitingSelection(int consumableId) async {
    final row = await customSelect(
      'SELECT 1 FROM printer_channels pc '
      'JOIN consumables c ON c.id = pc.consumable_id '
      'WHERE pc.consumable_id = ? AND pc.farm_roll_paused = ? '
      "AND c.inventory_scope = 'personal' LIMIT 1",
      variables: [
        Variable(consumableId),
        Variable(ChannelRollHoldState.awaitingSelection.dbValue),
      ],
    ).getSingleOrNull();
    return row != null;
  }

  /// Returns the physical channel indexes currently frozen for maintenance.
  /// Used by realtime task accounting so a printer progress jump during a
  /// repair cannot deduct the skipped grams after the roll is restored.
  Future<Set<int>> getMaintenancePausedChannelIndexes(int printerId) async {
    final rows = await customSelect(
      'SELECT channel_index FROM printer_channels '
      'WHERE printer_id = ? AND farm_roll_paused > 0',
      variables: [Variable(printerId)],
    ).get();
    return {for (final row in rows) row.read<int>('channel_index')};
  }

  Future<Set<String>> getMaintenancePausedTrayUuids(int printerId) async {
    final rows = await customSelect(
      'SELECT c.tray_uuid FROM printer_channels pc '
      'JOIN consumables c ON c.id = pc.consumable_id '
      'WHERE pc.printer_id = ? AND pc.farm_roll_paused > 0 '
      'AND c.tray_uuid IS NOT NULL AND c.tray_uuid != \'\'',
      variables: [Variable(printerId)],
    ).get();
    return {
      for (final row in rows)
        if (row.read<String?>('tray_uuid') case final uuid?) uuid,
    };
  }

  /// 新建打印机，并按通道数自动创建对应数量的通道槽位。事务保证完整性。
  Future<int> addPrinter({
    required String brand,
    required String model,
    required int channelCount,
    String? imageAsset,
    bool isCustomImage = false,
    String? name,
    String? note,
  }) {
    return transaction(() async {
      final id = await into(printers).insert(
        PrintersCompanion.insert(
          brand: brand,
          model: model,
          channelCount: Value(channelCount),
          imageAsset: Value(imageAsset),
          isCustomImage: Value(isCustomImage),
          name: Value(name),
          note: Value(note),
        ),
      );
      final labels = _channelLabels(channelCount);
      for (var i = 0; i < channelCount; i++) {
        await into(printerChannels).insert(
          PrinterChannelsCompanion.insert(
            printerId: id,
            channelIndex: i,
            label: Value(labels[i]),
          ),
        );
      }
      return id;
    });
  }

  /// Creates a printer from explicit physical feed sources instead of a
  /// synthetic A/B/C/D channel count.
  Future<int> addPrinterWithFeedConfiguration({
    required String brand,
    required String model,
    required PrinterFeedConfiguration feedConfiguration,
    String? imageAsset,
    bool isCustomImage = false,
    String? name,
    String? note,
  }) {
    return transaction(() async {
      final slots = feedConfiguration.slots;
      final id = await into(printers).insert(
        PrintersCompanion.insert(
          brand: brand,
          model: model,
          channelCount: Value(slots.length),
          imageAsset: Value(imageAsset),
          isCustomImage: Value(isCustomImage),
          name: Value(name),
          note: Value(note),
        ),
      );
      await _insertFeedSlots(id, slots);
      return id;
    });
  }

  Future<void> _insertFeedSlots(
    int printerId,
    Iterable<PrinterFeedSlotDefinition> slots,
  ) async {
    for (final slot in slots) {
      await into(printerChannels).insert(
        PrinterChannelsCompanion.insert(
          printerId: printerId,
          channelIndex: slot.channelIndex,
          label: Value(slot.label),
        ),
      );
    }
  }

  Future<int> deletePrinter(int id) {
    return (delete(printers)..where((t) => t.id.equals(id))).go();
  }

  /// 给通道装入一卷耗材。
  ///
  /// 农场槽位只维护一个“槽内当前克数”，不存在另一份“装入克数”。
  /// AMS 与外挂料位装入新卷时都把这个值重置为 1000g；打印结算直接
  /// 扣减它，设备明确报告无料时再清为 0 并解除绑定。
  Future<void> bindConsumable(
    int channelId,
    int consumableId, {
    FarmRollLoadAuthorization farmLoadAuthorization =
        FarmRollLoadAuthorization.none,
    String? physicalSpoolUid,
  }) async {
    return transaction(
      () => _bindConsumable(
        channelId,
        consumableId,
        farmLoadAuthorization: farmLoadAuthorization,
        physicalSpoolUid: physicalSpoolUid,
      ),
    );
  }

  Future<void> _bindConsumable(
    int channelId,
    int consumableId, {
    required FarmRollLoadAuthorization farmLoadAuthorization,
    String? physicalSpoolUid,
  }) async {
    final channel = await (select(
      printerChannels,
    )..where((t) => t.id.equals(channelId))).getSingleOrNull();
    if (channel == null) throw StateError('供料位不存在');

    final item = await _consumableDao.getById(consumableId);
    if (item == null) {
      throw StateError('所选耗材已无可用库存');
    }
    final scope = await customSelect(
      'SELECT inventory_scope, farm_workspace_id FROM consumables WHERE id = ?',
      variables: [Variable(consumableId)],
    ).getSingle();
    final farmInventory = scope.read<String>('inventory_scope') == 'farm';
    if (farmInventory) {
      if (channel.consumableId == consumableId &&
          channel.loadedRemainingGrams > 0) {
        final loadedIdentity = await customSelect(
          'SELECT loaded_spool_uid FROM printer_channels WHERE id = ?',
          variables: [Variable(channelId)],
        ).getSingle();
        final currentSpoolUid = loadedIdentity.read<String?>(
          'loaded_spool_uid',
        );
        if (physicalSpoolUid?.trim().isNotEmpty == true &&
            currentSpoolUid != physicalSpoolUid!.trim()) {
          throw StateError('槽内是同款但不同的物理卷，请使用换卷流程');
        }
        await resumeFarmChannelRoll(channelId);
        return;
      }
      if (channel.consumableId != null &&
          channel.consumableId != consumableId &&
          channel.loadedRemainingGrams > 0) {
        throw StateError('槽内农场耗材尚未耗尽，不能直接替换');
      }
      final workspaceId = scope.read<String?>('farm_workspace_id');
      if (workspaceId == null || workspaceId.isEmpty) {
        throw StateError('农场耗材缺少所属农场，无法装机');
      }
      if (farmLoadAuthorization == FarmRollLoadAuthorization.none) {
        throw StateError('未识别到拓竹 RFID，必须由当前农场成员确认耗材后才能扣减 1 卷库存');
      }
      final deducted = await customUpdate(
        'UPDATE consumables SET remaining_grams = remaining_grams - ?, '
        'updated_at = ? WHERE id = ? AND inventory_scope = \'farm\' '
        'AND farm_workspace_id = ? AND remaining_grams >= ?',
        variables: [
          const Variable(_farmRollGrams),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(consumableId),
          Variable(workspaceId),
          const Variable(_farmRollGrams),
        ],
        updates: {consumables},
      );
      if (deducted != 1) {
        throw StateError('该耗材的仓库整卷库存不足');
      }
      await (update(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).write(
        PrinterChannelsCompanion(
          consumableId: Value(consumableId),
          loadedRemainingGrams: const Value(_farmRollGrams),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = 0, loaded_spool_uid = ? '
        'WHERE id = ?',
        variables: [
          Variable(
            physicalSpoolUid?.trim().isNotEmpty == true
                ? physicalSpoolUid!.trim()
                : _uuid.v4(),
          ),
          Variable(channelId),
        ],
        updates: {printerChannels},
      );
      await customInsert(
        'INSERT INTO studio_inventory_events '
        '(id, workspace_id, consumable_id, event_type, delta_grams, reason, created_at) '
        'VALUES (?, ?, ?, \'reserve\', ?, ?, ?)',
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          Variable(consumableId),
          const Variable(-_farmRollGrams),
          Variable('装入打印机 #${channel.printerId} · ${channel.label}（1 卷）'),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      return;
    }
    if (item.remainingGrams <= 0) {
      throw StateError('所选耗材已无可用库存');
    }
    final rfidBinding = await _consumableDao.getRfidSpoolBindingById(
      consumableId,
    );
    final isIndividualSpool = await _consumableDao.isIndividualPersonalSpool(
      consumableId,
    );
    if (rfidBinding?.tagUid.isNotEmpty == true && !rfidBinding!.isActive) {
      throw StateError('该标签周期已经结束，请选择当前耗材卷');
    }
    if (isIndividualSpool) {
      await PersonalSpoolHandoff(attachedDatabase).assertNotReservedElsewhere(
        consumableId,
        channel.printerId,
        channel.channelIndex,
      );
    }
    if (channel.consumableId != null && channel.consumableId != consumableId) {
      throw StateError('供料位已有耗材，请使用换卷流程保留旧卷及任务历史');
    }

    final batchSpec = await customSelect(
      'SELECT roll_count, grams_per_roll FROM studio_inventory_batch_items '
      'WHERE consumable_id = ?',
      variables: [Variable(consumableId)],
    ).getSingleOrNull();
    final gramsInRoll = math.min(
      item.remainingGrams,
      isIndividualSpool
          ? item.totalGrams
          : batchSpec?.read<double>('grams_per_roll') ?? gramsPerRoll,
    );
    if (channel.consumableId == consumableId) {
      if (channel.loadedRemainingGrams <= 0 && gramsInRoll > 0) {
        await (update(
          printerChannels,
        )..where((t) => t.id.equals(channelId))).write(
          PrinterChannelsCompanion(
            loadedRemainingGrams: Value(gramsInRoll),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
      return;
    }
    final rows = await customSelect(
      'SELECT COUNT(*) AS bound_count FROM printer_channels '
      'WHERE consumable_id = ? AND id != ?',
      variables: [Variable(consumableId), Variable(channelId)],
    ).getSingle();
    final boundCount = rows.read<int>('bound_count');
    final rolls = isIndividualSpool
        ? 1
        : batchSpec == null
        ? inventoryRollCount(item.remainingGrams)
        : (item.remainingGrams /
                  math.max(1, batchSpec.read<double>('grams_per_roll')))
              .ceil();
    if (boundCount >= rolls) {
      throw StateError('该耗材的 $rolls 卷库存均已绑定到其他供料位');
    }

    await (update(printerChannels)..where((t) => t.id.equals(channelId))).write(
      PrinterChannelsCompanion(
        consumableId: Value(consumableId),
        loadedRemainingGrams: Value(gramsInRoll),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await customUpdate(
      'UPDATE printer_channels SET loaded_spool_uid = ? WHERE id = ?',
      variables: [
        Variable(
          physicalSpoolUid?.trim().isNotEmpty == true
              ? physicalSpoolUid!.trim()
              : item.trayUuid?.trim().isNotEmpty == true
              ? item.trayUuid!.trim()
              : rfidBinding?.tagUid.isNotEmpty == true
              ? rfidBinding!.tagUid
              : null,
        ),
        Variable(channelId),
      ],
      updates: {printerChannels},
    );
    await PersonalSpoolHandoff(attachedDatabase).record(
      channel,
      consumableId,
      'spool_loaded',
      before: gramsInRoll,
      after: gramsInRoll,
    );
  }

  Future<void> _unloadChannelPreservingFarmStock(
    int channelId, {
    required String reason,
  }) async {
    final row = await customSelect(
      'SELECT pc.id, pc.printer_id, pc.channel_index, pc.label, '
      'pc.consumable_id, pc.loaded_remaining_grams, c.inventory_scope, '
      'c.farm_workspace_id FROM printer_channels pc '
      'LEFT JOIN consumables c ON c.id = pc.consumable_id WHERE pc.id = ?',
      variables: [Variable(channelId)],
    ).getSingleOrNull();
    if (row == null) return;
    final consumableId = row.read<int?>('consumable_id');
    final remaining = row
        .read<double>('loaded_remaining_grams')
        .clamp(0.0, _farmRollGrams)
        .toDouble();
    final farmInventory = row.read<String?>('inventory_scope') == 'farm';
    final workspaceId = row.read<String?>('farm_workspace_id');
    if (!farmInventory && consumableId != null) {
      final handoff = PersonalSpoolHandoff(attachedDatabase);
      if (await handoff.hasPending(consumableId)) {
        throw StateError('该卷仍有未结算任务，请使用换卷接续，或维修暂存保留关联');
      }
      final channel = await (select(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).getSingle();
      final item = await _consumableDao.getById(consumableId);
      if (item != null) {
        await handoff.record(
          channel,
          consumableId,
          'spool_unloaded',
          before: item.remainingGrams,
          after: item.remainingGrams,
        );
      }
    }
    if (farmInventory &&
        consumableId != null &&
        workspaceId != null &&
        remaining > 0) {
      await customUpdate(
        'UPDATE consumables SET remaining_grams = remaining_grams + ?, '
        'updated_at = ? WHERE id = ? AND inventory_scope = \'farm\' '
        'AND farm_workspace_id = ?',
        variables: [
          Variable(remaining),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(consumableId),
          Variable(workspaceId),
        ],
        updates: {consumables},
      );
      await customInsert(
        'INSERT INTO studio_inventory_events '
        '(id, workspace_id, consumable_id, event_type, delta_grams, reason, created_at) '
        "VALUES (?, ?, ?, 'returnToStock', ?, ?, ?)",
        variables: [
          Variable(_uuid.v4()),
          Variable(workspaceId),
          Variable(consumableId),
          Variable(remaining),
          Variable('$reason · ${row.read<String>('label')}'),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
    }
    await customUpdate(
      'UPDATE printer_channels SET consumable_id = NULL, '
      'loaded_remaining_grams = 0, loaded_spool_uid = NULL, '
      'farm_roll_paused = 0, updated_at = ? WHERE id = ?',
      variables: [
        Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        Variable(channelId),
      ],
      updates: {printerChannels},
    );
  }

  /// 解绑通道。农场卷会把槽内剩余克数原子归还仓库。
  ///
  /// 自动拔料弹窗会先冻结个人卷，防止等待用户选择时继续扣量。只有用户在
  /// 该弹窗明确确认“余料回库”时才传 [confirmDetectedRemoval]，事务会清除
  /// 临时冻结并解绑，个人库存余量保持不变。
  Future<void> unbindChannel(
    int channelId, {
    bool confirmDetectedRemoval = false,
    int? expectedConsumableId,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    await transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final state = await customSelect(
        'SELECT consumable_id, farm_roll_paused FROM printer_channels WHERE id = ?',
        variables: [Variable(channelId)],
      ).getSingleOrNull();
      if (expectedConsumableId != null &&
          state?.read<int?>('consumable_id') != expectedConsumableId) {
        throw StateError('料位中的耗材已经变化，本次取下操作未执行');
      }
      final holdState = ChannelRollHoldState.fromDb(
        state?.read<int?>('farm_roll_paused'),
      );
      if (holdState == ChannelRollHoldState.maintenance &&
          !confirmDetectedRemoval) {
        throw StateError('该卷正在维修暂存，请先重新装回后再卸下');
      }
      final consumableId = state?.read<int?>('consumable_id');
      if (consumableId != null &&
          !await _consumableDao.isFarmConsumable(consumableId)) {
        final item = await _consumableDao.getById(consumableId);
        final binding = await _consumableDao.getRfidSpoolBindingById(
          consumableId,
        );
        // UID 只能证明资料卡，不能证明下一次装入的是同一实体卷。保留
        // active 生命周期供云同步，但用本地状态 2 冻结扣量并要求选卷。
        if (item != null &&
            item.remainingGrams > 0 &&
            binding?.isActive == true &&
            isConsumableRfidTagType(binding?.tagType)) {
          await customUpdate(
            'UPDATE printer_channels SET farm_roll_paused = ?, updated_at = ? '
            'WHERE id = ? AND consumable_id = ?',
            variables: [
              Variable(ChannelRollHoldState.awaitingSelection.dbValue),
              Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
              Variable(channelId),
              Variable(consumableId),
            ],
            updates: {printerChannels},
          );
          return;
        }
      }
      await _unloadChannelPreservingFarmStock(channelId, reason: '手动卸下打印机耗材');
    });
  }

  /// 堵头或维修时临时取下当前物理卷。
  ///
  /// 个人库存和农场库存都只暂停槽位，不解绑、不结算、不修改任何克数。
  /// `farm_roll_paused` 是已有数据库列名，现作为通用维修暂停标记使用。
  Future<void> pauseChannelRollForMaintenance(
    int channelId, {
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    return transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final row = await customSelect(
        'SELECT pc.id, pc.consumable_id, pc.loaded_remaining_grams, '
        'pc.farm_roll_paused, '
        'c.inventory_scope, c.remaining_grams FROM printer_channels pc '
        'LEFT JOIN consumables c ON c.id = pc.consumable_id '
        'WHERE pc.id = ?',
        variables: [Variable(channelId)],
      ).getSingleOrNull();
      if (row == null || row.read<int?>('consumable_id') == null) {
        throw StateError('槽位没有可暂存的耗材');
      }
      if (ChannelRollHoldState.fromDb(row.read<int?>('farm_roll_paused')) ==
          ChannelRollHoldState.awaitingSelection) {
        throw StateError('该料位正等待确认实际装入的具体卷');
      }
      final isFarm = row.read<String?>('inventory_scope') == 'farm';
      final availableGrams = isFarm
          ? row.read<double>('loaded_remaining_grams')
          : row.read<double?>('remaining_grams') ?? 0;
      if (availableGrams <= 0) {
        throw StateError('该卷已经耗尽，请直接取下空卷');
      }
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = ?, updated_at = ? '
        'WHERE id = ?',
        variables: [
          Variable(ChannelRollHoldState.maintenance.dbValue),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(channelId),
        ],
        updates: {printerChannels},
      );
    });
  }

  /// 将已物理拔出的个人 CUID/FUID 卷置为待选择状态。
  ///
  /// 旧卷仍留在原通道并保持暂停，因此余量与未结算任务都不会丢失。
  /// 标签生命周期保持 active 以便安全同步；本地状态 2 使同 UID 再次
  /// 装入时必须选择具体库存卷。选择原卷可调用
  /// [resumePreparedPersonalSpoolReplacement]。
  Future<void> preparePersonalSpoolReplacement(
    int channelId, {
    required int expectedConsumableId,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) {
    return transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final row = await customSelect(
        'SELECT pc.consumable_id, pc.farm_roll_paused, c.inventory_scope, '
        'c.remaining_grams FROM printer_channels pc '
        'LEFT JOIN consumables c ON c.id = pc.consumable_id WHERE pc.id = ?',
        variables: [Variable(channelId)],
      ).getSingleOrNull();
      if (row?.read<int?>('consumable_id') != expectedConsumableId) {
        throw StateError('料位中的耗材已经变化，本次换卷准备未执行');
      }
      if (row!.read<String?>('inventory_scope') == 'farm') {
        throw StateError('个人换卷流程不能处理农场库存');
      }
      if ((row.read<double?>('remaining_grams') ?? 0) <= 0) {
        throw StateError('该卷已经耗尽，请使用“确认用完”结算');
      }
      final binding = await _consumableDao.getRfidSpoolBindingById(
        expectedConsumableId,
      );
      final reusableTag =
          binding?.tagUid.isNotEmpty == true &&
          isConsumableRfidTagType(binding?.tagType);
      if (reusableTag) {
        if (!binding!.isActive) {
          throw StateError('该标签卷已经耗尽或归档，不能进入待换卷状态');
        }
      }
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = ?, updated_at = ? '
        'WHERE id = ? AND consumable_id = ?',
        variables: [
          Variable(
            reusableTag
                ? ChannelRollHoldState.awaitingSelection.dbValue
                : ChannelRollHoldState.maintenance.dbValue,
          ),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(channelId),
          Variable(expectedConsumableId),
        ],
        updates: {printerChannels},
      );
    });
  }

  /// 取消待换卷状态并重新装回同一具体卷，不创建新周期或拆分任务。
  Future<void> resumePreparedPersonalSpoolReplacement(
    int channelId, {
    required int expectedConsumableId,
    bool keepPaused = false,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) {
    return transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final row = await customSelect(
        'SELECT pc.consumable_id, pc.farm_roll_paused, c.inventory_scope, '
        'c.remaining_grams FROM printer_channels pc '
        'LEFT JOIN consumables c ON c.id = pc.consumable_id WHERE pc.id = ?',
        variables: [Variable(channelId)],
      ).getSingleOrNull();
      if (row?.read<int?>('consumable_id') != expectedConsumableId ||
          !ChannelRollHoldState.fromDb(
            row?.read<int?>('farm_roll_paused'),
          ).isHeld) {
        throw StateError('料位中的耗材或待换卷状态已经变化');
      }
      if (row!.read<String?>('inventory_scope') == 'farm' ||
          (row.read<double?>('remaining_grams') ?? 0) <= 0) {
        throw StateError('当前具体卷不能继续使用');
      }
      final binding = await _consumableDao.getRfidSpoolBindingById(
        expectedConsumableId,
      );
      if (binding?.tagUid.isNotEmpty == true &&
          isConsumableRfidTagType(binding?.tagType)) {
        if (!binding!.isActive) {
          throw StateError('该标签卷已经耗尽或归档，不能继续使用');
        }
      }
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = ?, updated_at = ? '
        'WHERE id = ? AND consumable_id = ?',
        variables: [
          Variable(
            keepPaused
                ? ChannelRollHoldState.maintenance.dbValue
                : ChannelRollHoldState.loaded.dbValue,
          ),
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(channelId),
          Variable(expectedConsumableId),
        ],
        updates: {printerChannels},
      );
    });
  }

  /// 维修完成后重新启用槽位，原绑定和克数保持不变。
  Future<void> resumeChannelRollAfterMaintenance(
    int channelId, {
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    return transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final row = await customSelect(
        'SELECT farm_roll_paused FROM printer_channels WHERE id = ?',
        variables: [Variable(channelId)],
      ).getSingleOrNull();
      final state = ChannelRollHoldState.fromDb(
        row?.read<int?>('farm_roll_paused'),
      );
      if (state == ChannelRollHoldState.awaitingSelection) {
        throw StateError('请先确认实际装入的是哪一卷耗材');
      }
      if (state != ChannelRollHoldState.maintenance) return;
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = 0, updated_at = ? '
        'WHERE id = ? AND consumable_id IS NOT NULL '
        'AND loaded_remaining_grams > 0 AND farm_roll_paused = ?',
        variables: [
          Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable(channelId),
          Variable(ChannelRollHoldState.maintenance.dbValue),
        ],
        updates: {printerChannels},
      );
    });
  }

  /// 兼容原有农场调用；维修暂停现已同时支持个人库存。
  Future<void> pauseFarmChannelRollForMaintenance(int channelId) =>
      pauseChannelRollForMaintenance(channelId);

  /// 兼容原有农场调用；维修恢复现已同时支持个人库存。
  Future<void> resumeFarmChannelRoll(int channelId) =>
      resumeChannelRollAfterMaintenance(channelId);

  /// Applies a physical remaining-weight observation to a loaded farm roll.
  ///
  /// Returns true when the target channel is currently bound to a farm SKU.
  /// Farm RFID/telemetry must update the slot roll, never the warehouse count.
  Future<bool> syncFarmChannelLoadedRemaining({
    required int printerId,
    required int channelIndex,
    required double remainingGrams,
    int? expectedConsumableId,
  }) async {
    final row = await customSelect(
      'SELECT pc.id, pc.consumable_id, c.inventory_scope '
      'FROM printer_channels pc '
      'LEFT JOIN consumables c ON c.id = pc.consumable_id '
      'WHERE pc.printer_id = ? AND pc.channel_index = ? LIMIT 1',
      variables: [Variable(printerId), Variable(channelIndex)],
    ).getSingleOrNull();
    if (row == null || row.read<String?>('inventory_scope') != 'farm') {
      return false;
    }
    final consumableId = row.read<int?>('consumable_id');
    if (expectedConsumableId != null && consumableId != expectedConsumableId) {
      return false;
    }
    final normalized = remainingGrams.clamp(0.0, _farmRollGrams).toDouble();
    await customUpdate(
      'UPDATE printer_channels SET loaded_remaining_grams = ?, '
      'farm_roll_paused = 0, updated_at = ? '
      'WHERE id = ?',
      variables: [
        Variable(normalized),
        Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        Variable(row.read<int>('id')),
      ],
      updates: {printerChannels},
    );
    return true;
  }

  /// 换卷时保留旧卷余量、封存任务的旧卷段，再原子绑定新卷。
  /// 手动余量只记录尚未入账的差额，不重记整卷累计消耗。
  Future<void> changeRoll({
    required int channelId,
    required int newConsumableId,
    double? manualRemainingGrams,
    FarmRollLoadAuthorization farmLoadAuthorization =
        FarmRollLoadAuthorization.none,
    String? physicalSpoolUid,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    return transaction(() async {
      final ch = await (select(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).getSingleOrNull();
      if (ch == null) {
        throw StateError('供料位不存在');
      }
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      await _assertConsumablePersonalOwnerAccess(
        newConsumableId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final identity = await customSelect(
        'SELECT loaded_spool_uid FROM printer_channels WHERE id = ?',
        variables: [Variable(channelId)],
      ).getSingle();
      final loadedSpoolUid = identity.read<String?>('loaded_spool_uid');
      final replacingPhysicalSpool =
          physicalSpoolUid?.trim().isNotEmpty == true &&
          loadedSpoolUid != physicalSpoolUid!.trim();
      if (ch.consumableId == newConsumableId && !replacingPhysicalSpool) {
        // 聚合库存中的下一卷可能与空卷属于同一条耗材记录。此时不是
        // “没有变化”，而是同款新卷装入，槽内当前克数必须重新置为 1000g。
        if (ch.loadedRemainingGrams <= 0) {
          await _bindConsumable(
            channelId,
            newConsumableId,
            farmLoadAuthorization: farmLoadAuthorization,
            physicalSpoolUid: physicalSpoolUid,
          );
        } else {
          await customUpdate(
            'UPDATE printer_channels SET farm_roll_paused = 0, '
            'updated_at = ? WHERE id = ?',
            variables: [
              Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
              Variable(channelId),
            ],
            updates: {printerChannels},
          );
        }
        return;
      }

      final oldConsumableId = ch.consumableId;
      if (oldConsumableId != null) {
        final oldScope = await customSelect(
          'SELECT inventory_scope FROM consumables WHERE id = ?',
          variables: [Variable(oldConsumableId)],
        ).getSingleOrNull();
        if (oldScope?.read<String>('inventory_scope') == 'farm') {
          if (ch.loadedRemainingGrams > 0) {
            await _unloadChannelPreservingFarmStock(
              channelId,
              reason: '更换农场物理卷并归还剩余量',
            );
          } else {
            await customUpdate(
              'UPDATE printer_channels SET consumable_id = NULL, '
              'loaded_remaining_grams = 0, loaded_spool_uid = NULL, '
              'farm_roll_paused = 0, updated_at = ? WHERE id = ?',
              variables: [
                Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
                Variable(channelId),
              ],
              updates: {printerChannels},
            );
          }
          if (ch.loadedRemainingGrams <= 0) {
            await into(usageLogs).insert(
              UsageLogsCompanion.insert(
                printerId: Value(ch.printerId),
                channelIndex: Value(ch.channelIndex),
                consumableId: Value(oldConsumableId),
                consumedGrams: const Value(_farmRollGrams),
                finished: const Value(true),
                note: const Value('农场槽位空卷更换'),
              ),
            );
          }
          await _bindConsumable(
            channelId,
            newConsumableId,
            farmLoadAuthorization: farmLoadAuthorization,
            physicalSpoolUid: physicalSpoolUid,
          );
          return;
        }
        final oldConsumable = await attachedDatabase.consumableDao.getById(
          oldConsumableId,
        );
        if (oldConsumable != null) {
          await PersonalSpoolHandoff(attachedDatabase).unload(
            ch,
            oldConsumable,
            newConsumableId: newConsumableId,
            measuredRemaining: manualRemainingGrams,
          );
        }
      }

      // 解绑旧卷（如果有）
      await (update(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).write(
        PrinterChannelsCompanion(
          consumableId: const Value(null),
          loadedRemainingGrams: const Value(0),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = 0, '
        'loaded_spool_uid = NULL WHERE id = ?',
        variables: [Variable(channelId)],
        updates: {printerChannels},
      );

      // 绑定新卷
      await _bindConsumable(
        channelId,
        newConsumableId,
        farmLoadAuthorization: farmLoadAuthorization,
        physicalSpoolUid: physicalSpoolUid,
      );
    });
  }

  /// 标记通道耗材已用完并解绑通道。
  /// 事务保证三步一致。用完以后该通道变为无耗材状态。
  /// 农场整卷在装机时已经从仓库扣除，因此耗尽时只结束槽位卷，绝不再
  /// 扣仓库；普通用户耗材继续沿用原有的库存克数逻辑。
  Future<void> finishChannel(
    int channelId, {
    int? expectedConsumableId,
    bool enforcePersonalOwner = false,
    String? personalOwnerAccount,
  }) async {
    return transaction(() async {
      await _assertChannelPersonalOwnerAccess(
        channelId,
        enforce: enforcePersonalOwner,
        ownerAccount: personalOwnerAccount,
      );
      final ch = await (select(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).getSingleOrNull();
      if (ch == null || ch.consumableId == null) return;
      if (expectedConsumableId != null &&
          ch.consumableId != expectedConsumableId) {
        throw StateError('料位中的耗材已经变化，本次耗尽操作未执行');
      }
      if ((await _loadPausedChannelIds()).contains(channelId)) {
        throw StateError('该卷正在维修暂存，请先重新装回后再操作');
      }
      final consumableId = ch.consumableId!;
      final consumable = await attachedDatabase.consumableDao.getById(
        consumableId,
      );
      if (consumable != null) {
        const rollGrams = 1000.0;
        final farmInventory = await _consumableDao.isFarmConsumable(
          consumableId,
        );
        if (farmInventory) {
          await into(usageLogs).insert(
            UsageLogsCompanion.insert(
              printerId: Value(ch.printerId),
              channelIndex: Value(ch.channelIndex),
              consumableId: Value(consumableId),
              consumedGrams: const Value(rollGrams),
              finished: const Value(true),
            ),
          );
        } else {
          await PersonalSpoolHandoff(attachedDatabase).finish(ch, consumable);
        }
      }
      await (update(
        printerChannels,
      )..where((t) => t.id.equals(channelId))).write(
        PrinterChannelsCompanion(
          consumableId: const Value(null),
          loadedRemainingGrams: const Value(0),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await customUpdate(
        'UPDATE printer_channels SET farm_roll_paused = 0, '
        'loaded_spool_uid = NULL WHERE id = ?',
        variables: [Variable(channelId)],
        updates: {printerChannels},
      );
    });
  }

  Future<void> _assertChannelPersonalOwnerAccess(
    int channelId, {
    required bool enforce,
    required String? ownerAccount,
  }) async {
    if (!enforce) return;
    final row = await customSelect(
      'SELECT consumable_id FROM printer_channels WHERE id = ? LIMIT 1',
      variables: [Variable<int>(channelId)],
    ).getSingleOrNull();
    final consumableId = row?.read<int?>('consumable_id');
    if (consumableId == null) return;
    await _assertConsumablePersonalOwnerAccess(
      consumableId,
      enforce: true,
      ownerAccount: ownerAccount,
    );
  }

  Future<void> _assertConsumablePersonalOwnerAccess(
    int consumableId, {
    required bool enforce,
    required String? ownerAccount,
  }) async {
    if (!enforce) return;
    final allowed = await _consumableDao.ensurePersonalConsumableAccess(
      consumableId,
      ownerAccount: ownerAccount,
      claimAnonymous: true,
    );
    if (!allowed) {
      throw StateError('该料位属于其他 Sohun 账号，请切回原账号后操作');
    }
  }

  /// Reconciles the printer's physical external feed inputs.
  ///
  /// Live sensor count is authoritative. A legacy single `A` channel is moved
  /// to the reserved external channel only when the printer reports no AMS,
  /// preserving any existing binding during migration.
  Future<void> syncExternalFeedChannels(
    int printerId, {
    required int externalInputCount,
    required bool hasAms,
  }) async {
    final slots = externalFeedSlots(externalInputCount);
    await transaction(() async {
      final rows = await (select(
        printerChannels,
      )..where((table) => table.printerId.equals(printerId))).get();
      final byIndex = {for (final row in rows) row.channelIndex: row};

      // Legacy/custom configurations with no external input can report
      // an external sensor while the personal app intentionally exposes no
      // external feed slot. Remove only unbound legacy rows; a bound row is
      // retained for inventory history and hidden by the printer card.
      if (slots.isEmpty) {
        for (final row in rows) {
          if (!isExternalFeedChannel(row.channelIndex) ||
              row.consumableId != null) {
            continue;
          }
          await (delete(
            printerChannels,
          )..where((table) => table.id.equals(row.id))).go();
        }
        await _refreshChannelCount(printerId);
        return;
      }

      if (!hasAms && !byIndex.containsKey(externalFeedRightChannel)) {
        final legacy = rows.where(
          (row) =>
              row.channelIndex == 0 &&
              (row.label == 'A' || row.label == '通道 A'),
        );
        if (legacy.length == 1) {
          final slot = slots.firstWhere(
            (item) => item.channelIndex == externalFeedRightChannel,
          );
          await (update(
            printerChannels,
          )..where((table) => table.id.equals(legacy.single.id))).write(
            PrinterChannelsCompanion(
              channelIndex: const Value(externalFeedRightChannel),
              label: Value(slot.label),
              updatedAt: Value(DateTime.now()),
            ),
          );
          byIndex.remove(0);
          byIndex[externalFeedRightChannel] = legacy.single;
        }
      }

      for (final slot in slots) {
        final existing = byIndex[slot.channelIndex];
        if (existing == null) {
          await into(printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: slot.channelIndex,
              label: Value(slot.label),
            ),
          );
        } else if (existing.label != slot.label) {
          await (update(
            printerChannels,
          )..where((table) => table.id.equals(existing.id))).write(
            PrinterChannelsCompanion(
              label: Value(slot.label),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
      }

      final desired = slots.map((slot) => slot.channelIndex).toSet();
      for (final row in rows) {
        if (!isExternalFeedChannel(row.channelIndex) ||
            desired.contains(row.channelIndex) ||
            row.consumableId != null) {
          continue;
        }
        await (delete(
          printerChannels,
        )..where((table) => table.id.equals(row.id))).go();
      }
      await _refreshChannelCount(printerId);
    });
  }

  /// Clears an external slot as soon as the printer reports no filament.
  /// A later physical reload is configured as a fresh 1000g farm roll.
  Future<void> syncExternalFeedOccupancy(
    int printerId,
    List<bool?> filamentPresent, {
    bool unbindEmpty = true,
  }) async {
    if (filamentPresent.isEmpty || !unbindEmpty) return;
    final channelIndexes = filamentPresent.length == 1
        ? const [externalFeedRightChannel]
        : const [externalFeedRightChannel, externalFeedLeftChannel];
    await transaction(() async {
      for (
        var index = 0;
        index < math.min(filamentPresent.length, channelIndexes.length);
        index++
      ) {
        if (filamentPresent[index] != false) continue;
        final channel = await customSelect(
          'SELECT id FROM printer_channels WHERE printer_id = ? '
          'AND channel_index = ? AND farm_roll_paused = 0 LIMIT 1',
          variables: [Variable(printerId), Variable(channelIndexes[index])],
        ).getSingleOrNull();
        if (channel != null) {
          await _unloadChannelPreservingFarmStock(
            channel.read<int>('id'),
            reason: '外挂料位检测到耗材已取下',
          );
        }
      }
    });
  }

  /// 从 MQTT AMS 数据同步通道。
  ///
  /// 逻辑：
  /// 1. 查询当前数据库中的通道列表
  /// 2. 如果通道数 != amsTrays.length，自动调整（增加新通道或删除多余通道）
  /// 3. 对每个有料的 AMS 槽位（hasFilament=true），尝试匹配库存中的耗材
  ///    匹配规则：材质(trayType) + 颜色(trayColor 前6位hex) 精确匹配
  ///    如果匹配到且该通道未绑定耗材，自动绑定
  /// 4. 不覆盖用户已手动绑定的耗材（只绑定空通道）
  /// 从 MQTT AMS 数据同步通道数量，并自动绑定拓竹原厂料到库存耗材。
  ///
  /// 做两件事：
  /// 1. 根据 AMS 实际槽位数调整数据库通道数，使其对齐。
  /// 2. 对有 RFID 的拓竹原厂料，按 trayUuid 自动匹配库存耗材并绑定。
  ///    - 优先按 trayUuid 精确匹配已绑定的耗材（同一卷料重新装回）
  ///    - 找不到则按 trayInfoIdx + trayColor + trayType 模糊匹配未绑定的耗材
  ///    - 仍找不到则自动创建一条耗材记录并绑定（拓竹原厂料信息完整）
  /// 第三方料（无 RFID）不自动绑定，由用户手动操作。
  Future<void> syncChannelsFromAms(
    int printerId,
    List<AmsTray> amsTrays, {
    List<AmsUnit>? amsUnits,
    bool autoBindRfid = true,
    bool unbindEmpty = true,
    bool farmMode = false,
    String? personalOwnerAccount,
  }) async {
    final presentUnits = (amsUnits ?? const <AmsUnit>[])
        .where((unit) => unit.isPresent)
        .toList(growable: false);
    final physicalSlots = amsTrays
        .where((tray) => tray.amsId >= 0)
        .map((tray) => tray.globalSlot)
        .toSet();
    // null 表示这次增量消息没有 AMS 事实，不能据此删除旧槽位；显式空单元
    // 列表才表示打印机确认当前没有连接 AMS。
    if (physicalSlots.isEmpty &&
        (amsUnits == null || presentUnits.isNotEmpty)) {
      return;
    }

    return transaction(() async {
      final existingChannels =
          await (select(printerChannels)
                ..where((t) => t.printerId.equals(printerId))
                ..orderBy([(t) => OrderingTerm(expression: t.channelIndex)]))
              .get();

      final existingByIndex = {
        for (final channel in existingChannels) channel.channelIndex: channel,
      };

      // 设备明确报告没有 AMS：删除所有 AMS 槽位及其绑定。耗材库存记录
      // 本身仍保留；这里只清除物理位置。预留的外挂料位绝不能被误删。
      if (physicalSlots.isEmpty) {
        final pausedIds = await _loadPausedChannelIds(printerId: printerId);
        for (final channel in existingChannels) {
          if (isExternalFeedChannel(channel.channelIndex)) continue;
          if (pausedIds.contains(channel.id)) continue;
          // 老数据中的单外挂可能仍是 A/通道 A；外挂机同步会把它迁移到
          // 255，在并发状态推送下也先保留，避免误删真实外挂绑定。
          if (channel.channelIndex == 0 &&
              (channel.label == 'A' || channel.label == '通道 A')) {
            continue;
          }
          await _unloadChannelPreservingFarmStock(
            channel.id,
            reason: '设备确认 AMS 已断开',
          );
          await (delete(
            printerChannels,
          )..where((table) => table.id.equals(channel.id))).go();
        }
        await _refreshChannelCount(printerId);
        return;
      }

      final unitFacts = <int, ({int ordinal, AmsUnitType type})>{
        for (var index = 0; index < presentUnits.length; index++)
          presentUnits[index].id: (
            ordinal: index + 1,
            type: presentUnits[index].type,
          ),
      };

      // 1. 只创建协议实际报告的物理槽位。AMS HT 从全局槽位 16 开始，
      // 不能因此创建 0..15 的虚构空通道。
      for (final slot in physicalSlots.toList()..sort()) {
        final tray = amsTrays.firstWhere((item) => item.globalSlot == slot);
        final label = _amsChannelLabel(tray, unitFacts[tray.amsId]);
        if (!existingByIndex.containsKey(slot)) {
          await into(printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: slot,
              label: Value(label),
            ),
          );
        } else if (existingByIndex[slot]!.label != label) {
          await (update(printerChannels)
                ..where((table) => table.id.equals(existingByIndex[slot]!.id)))
              .write(
                PrinterChannelsCompanion(
                  label: Value(label),
                  updatedAt: Value(DateTime.now()),
                ),
              );
        }
      }
      for (final channel in existingChannels) {
        if (isExternalFeedChannel(channel.channelIndex)) continue;
        if (!physicalSlots.contains(channel.channelIndex) &&
            channel.consumableId == null) {
          await (delete(
            printerChannels,
          )..where((table) => table.id.equals(channel.id))).go();
        }
      }
      final actualCount =
          await (selectOnly(printerChannels)
                ..addColumns([printerChannels.id.count()])
                ..where(printerChannels.printerId.equals(printerId)))
              .map((row) => row.read(printerChannels.id.count()) ?? 0)
              .getSingle();
      await (update(printers)..where((t) => t.id.equals(printerId))).write(
        PrintersCompanion(channelCount: Value(actualCount)),
      );

      // 2. 拓竹原厂料自动绑定（数字孪生核心）
      // 只对有 RFID 的原厂料自动绑定，第三方料留给用户手动操作。
      // 已绑定的通道跳过（避免重复绑定）。
      // 注意：existingChannels 是 insert 之前查的列表，不包含新插入的通道，
      // 所以 _autoBindRfidConsumables 内部不再依赖此列表，而是按 channelIndex
      // 实时查询数据库获取真实通道（含新插入的），否则 firstWhere 走 orElse
      // 返回 id=-1，bindConsumable(-1) 静默失败。
      if (autoBindRfid) {
        await _autoBindRfidConsumables(
          printerId,
          amsTrays,
          farmMode: farmMode,
          personalOwnerAccount: personalOwnerAccount,
        );
      }

      // 3. 解绑物理已拔出但数据库仍绑定的通道
      // hasFilament=false 但 consumableId!=null 的通道，解绑并回库
      // consumables 表的 remainingGrams 已被实时扣减/RFID 同步更新过，
      // 解绑后旧料即"未用完卷"状态，库存页会正确显示，无需额外回库逻辑。
      if (unbindEmpty) {
        for (final tray in amsTrays) {
          if (!tray.hasFilamentObservation || tray.hasFilament) continue;
          final channels = await customSelect(
            'SELECT * FROM printer_channels WHERE printer_id = ? AND channel_index = ? AND consumable_id IS NOT NULL LIMIT 1',
            variables: [
              Variable<int>(printerId),
              Variable<int>(tray.globalSlot),
            ],
          ).get();
          if (channels.isEmpty) continue;
          if (ChannelRollHoldState.fromDb(
            channels.first.read<int?>('farm_roll_paused'),
          ).isHeld) {
            continue;
          }
          await _unloadChannelPreservingFarmStock(
            channels.first.read<int>('id'),
            reason: 'AMS 检测到耗材已取下',
          );
        }
      }
    });
  }

  /// 拓竹原厂料自动绑定：按 AMS 物理 tag_uid / 逻辑 trayUuid 匹配库存
  /// 耗材并绑定到对应通道。
  ///
  /// 绑定策略（三级）：
  /// 1. 通道已绑定 → 跳过
  /// 2. tag_uid 或 trayUuid 精确匹配库存已有耗材 → 绑定（同一卷料重新装回场景）
  /// 3. 模糊匹配未绑定的同 SKU+颜色+材质耗材 → 绑定（新料首次装入场景）
  /// 4. 都找不到 → 自动创建耗材记录并绑定（拓竹原厂料信息完整，可自动建档）
  ///
  /// 第三方料（isThirdParty 或 hasRfidInfo=false）不自动建档。
  /// 若第三方 RFID 载体已经在本地耗材库绑定了同一 tag_uid/trayUuid，则允许
  /// 按身份恢复到对应通道；未知第三方 UUID 仍保持未绑定，避免误认/建档。
  Future<void> _autoBindRfidConsumables(
    int printerId,
    List<AmsTray> amsTrays, {
    required bool farmMode,
    required String? personalOwnerAccount,
  }) async {
    final resolver = farmMode
        ? null
        : await PersonalAmsIdentityResolver.load(
            attachedDatabase,
            ownerAccount: personalOwnerAccount,
          );
    final counts = <String, int>{};
    for (final tray in amsTrays.where((t) => t.hasFilament)) {
      final keys = resolver?.resolve(tray.normalizedTagUid).collisionKeys;
      for (final identity
          in keys?.isNotEmpty == true
              ? keys!
              : {tray.physicalRfidIdentity.toLowerCase()}) {
        if (identity.isNotEmpty) {
          counts.update(identity, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }
    for (final tray in amsTrays) {
      // 只处理有料且有稳定身份的 AMS 槽位。官方 RFID 继续走完整的
      // 自动匹配/建档流程；第三方载体只有在本地已按 trayUuid 绑定时才放行。
      if (!tray.hasFilament) continue;
      final identityResolution = resolver?.resolve(tray.normalizedTagUid);
      if (identityResolution?.requiresConfirmation == true) continue;
      final canonicalTagUid =
          identityResolution?.tagUid ?? tray.normalizedTagUid;
      final registeredTagHistory =
          identityResolution?.history ??
          (personalOwnerAccount != null || tray.normalizedTagUid.isEmpty
              ? const <RfidSpoolBinding>[]
              : await _consumableDao.getAnyPersonalRfidSpoolHistory(
                  tray.normalizedTagUid,
                ));
      // A CUID may carry a copied Bambu payload. Known physical-tag bindings
      // take precedence over the manufacturer's name inside that payload.
      final isOfficialRfid =
          tray.isBambuOfficialRfid &&
          !registeredTagHistory.any((b) => b.tagType != 'ams');
      if (!isOfficialRfid && !tray.hasAmsRfidIdentity) continue;
      // A copied third-party payload may share tray_uuid across many cards.
      // Once the reader exposes tag_uid, only that physical identity may bind.
      final identityCandidates =
          !isOfficialRfid && tray.normalizedTagUid.isNotEmpty
          ? [canonicalTagUid]
          : tray.rfidIdentityCandidates;
      if (identityCandidates.isEmpty) continue;
      // For official spools tray_uuid is stable across the two faces of a
      // spool; for third-party CUID/FUID media tag_uid is the only stable
      // identity the AMS can expose. Keep both values as lookup candidates,
      // but use one deterministic key for channel movement bookkeeping.
      final physicalIdentity =
          isOfficialRfid && tray.normalizedTrayUuid.isNotEmpty
          ? tray.normalizedTrayUuid
          : canonicalTagUid.isNotEmpty
          ? canonicalTagUid
          : tray.physicalRfidIdentity;
      if (!isOfficialRfid &&
          (counts[physicalIdentity.toLowerCase()] ?? 0) > 1) {
        // Cloned UIDs in two occupied slots cannot identify an individual roll.
        continue;
      }
      final preBound = isOfficialRfid
          ? null
          : identityResolution?.isPersonalTag == true
          ? identityResolution!.currentConsumableId == null
                ? null
                : await _consumableDao.getById(
                    identityResolution.currentConsumableId!,
                  )
          : await _findBoundRfidConsumable(
              identityCandidates,
              allowLegacyTrayUuid: false,
              personalOwnerAccount: personalOwnerAccount,
            );
      if (!isOfficialRfid && preBound == null) continue;
      final preBoundBinding = preBound == null
          ? null
          : await _consumableDao.getRfidSpoolBindingById(preBound.id);
      if (!isOfficialRfid &&
          preBound != null &&
          await isPersonalSpoolAwaitingSelection(preBound.id)) {
        // The reusable card identifies material metadata, not the physical
        // roll that returned. A state-2 hold is released only by the picker.
        continue;
      }
      final reusableTag =
          !isOfficialRfid && preBoundBinding?.tagUid.isNotEmpty == true;
      final observedRemaining =
          !reusableTag && tray.hasValidRemain && tray.trayWeight > 0
          ? tray.remainingGrams
          : null;

      // 实时查询数据库获取真实通道（含本事务中刚插入的通道）
      // 不能依赖调用方传入的 existingChannels（那是 insert 之前的快照，
      // 新插入的通道不在列表里，会导致 firstWhere 走 orElse 返回 id=-1，
      // bindConsumable(-1) 静默失败）。
      final channelRows = await customSelect(
        'SELECT * FROM printer_channels WHERE printer_id = ? AND channel_index = ? LIMIT 1',
        variables: [Variable<int>(printerId), Variable<int>(tray.globalSlot)],
      ).get();
      if (channelRows.isEmpty) continue;
      final row = channelRows.first;
      final channelId = row.read<int>('id');
      final currentConsumableId = row.read<int?>('consumable_id');
      final currentPhysicalSpoolUid = row.read<String?>('loaded_spool_uid');
      final rollHoldState = ChannelRollHoldState.fromDb(
        row.read<int?>('farm_roll_paused'),
      );
      if (rollHoldState == ChannelRollHoldState.awaitingSelection) {
        continue;
      }
      final wasMaintenancePaused =
          rollHoldState == ChannelRollHoldState.maintenance;
      if (currentConsumableId != null) {
        if (!farmMode &&
            personalOwnerAccount != null &&
            !await _consumableDao.ensurePersonalConsumableAccess(
              currentConsumableId,
              ownerAccount: personalOwnerAccount,
            )) {
          // A shared Windows profile can keep this physical binding while a
          // different Sohun account is active. Do not reveal or mutate it;
          // switching back to its owner restores the same channel state.
          continue;
        }
        final current = await _consumableDao.getById(currentConsumableId);
        final currentBinding = current == null
            ? null
            : await _consumableDao.getRfidSpoolBindingById(current.id);
        if ((preBound == null || preBound.id == currentConsumableId) &&
            _matchesAmsIdentity(
              identityCandidates,
              values: [
                currentPhysicalSpoolUid,
                current?.trayUuid,
                currentBinding?.tagUid,
              ],
            )) {
          final currentIsFarm = await _consumableDao.isFarmConsumable(
            currentConsumableId,
          );
          if (currentIsFarm == farmMode) {
            // A historical CUID/FUID cycle must never be revived from a
            // rounded AMS reading. The replacement flow creates a fresh
            // inventory UID first, after which this branch sees an active
            // binding for the new cycle.
            if (!currentIsFarm &&
                currentBinding != null &&
                !currentBinding.isActive) {
              continue;
            }
            if (wasMaintenancePaused) {
              // A maintenance pause is a grams freeze. The first RFID packet
              // after reinsertion may be rounded or stale, so resume using the
              // exact preserved inventory value instead of overwriting it.
              await resumeChannelRollAfterMaintenance(channelId);
              continue;
            }
            final nextRemaining =
                observedRemaining ??
                (currentIsFarm
                    ? row.read<double>('loaded_remaining_grams')
                    : current!.remainingGrams);
            final farmSlotUpdated = await syncFarmChannelLoadedRemaining(
              printerId: printerId,
              channelIndex: tray.globalSlot,
              remainingGrams: nextRemaining,
              expectedConsumableId: currentConsumableId,
            );
            if (!farmSlotUpdated) {
              await _consumableDao.updateRfidSync(
                consumableId: currentConsumableId,
                remainingGrams: nextRemaining,
              );
            }
            if (wasMaintenancePaused) {
              await resumeChannelRollAfterMaintenance(channelId);
            }
            continue;
          }
        }
      }

      // 策略1：先按槽位保存的物理卷 UID 找回同一卷。农场聚合 SKU
      // 不把某一卷 RFID 写到 consumables.tray_uuid，因此跨槽移动必须
      // 从 loaded_spool_uid 恢复，才能支持同 SKU 的多卷官方料。
      final physicalSource = await _findPhysicalSource(
        identityCandidates,
        excludedChannelId: channelId,
        personalOwnerAccount: farmMode ? null : personalOwnerAccount,
      );
      final sourceMatchesScope =
          physicalSource != null &&
          (preBound == null ||
              preBound.id == physicalSource.read<int>('consumable_id')) &&
          (physicalSource.read<String>('inventory_scope') == 'farm') ==
              farmMode;
      int? targetId = sourceMatchesScope
          ? physicalSource.read<int>('consumable_id')
          : null;
      double? targetRemaining = sourceMatchesScope
          ? physicalSource.read<double>('loaded_remaining_grams')
          : null;

      // 策略2：兼容旧数据，按 consumables.tray_uuid 精确匹配。
      if (targetId == null) {
        final matched =
            preBound ??
            await _findBoundRfidConsumable(
              identityCandidates,
              allowLegacyTrayUuid: isOfficialRfid,
              personalOwnerAccount: farmMode ? null : personalOwnerAccount,
            );
        final matchedIsFarm = matched == null
            ? false
            : await _consumableDao.isFarmConsumable(matched.id);
        if (matched != null && matchedIsFarm == farmMode) {
          targetId = matched.id;
          targetRemaining = matched.remainingGrams;
        }
      }

      // 第三方 RFID 只允许恢复已经绑定的本地记录，不能因为 AMS 上报了
      // 一个未知 UUID 就按颜色/材质模糊匹配，或自动创建一卷耗材。
      if (!isOfficialRfid && targetId == null) continue;

      // 策略3：按 SKU+颜色+材质模糊匹配未绑定耗材
      if (targetId == null) {
        final fuzzyMatched = await _fuzzyMatchConsumable(
          tray,
          farmMode: farmMode,
          personalOwnerAccount: personalOwnerAccount,
        );
        if (fuzzyMatched != null) {
          targetId = fuzzyMatched.id;
          targetRemaining = fuzzyMatched.remainingGrams;
          if (!farmMode && tray.normalizedTrayUuid.isNotEmpty) {
            await _consumableDao.updateTrayUuid(
              targetId,
              tray.normalizedTrayUuid,
            );
          }
        }
      }

      // 策略4：自动创建耗材记录（拓竹原厂料信息完整）
      if (targetId == null && !farmMode) {
        final nominalGrams = tray.trayWeight > 0
            ? tray.trayWeight.toDouble().clamp(0.0, gramsPerRoll).toDouble()
            : gramsPerRoll;
        final initialRemaining = (observedRemaining ?? nominalGrams)
            .clamp(0.0, gramsPerRoll)
            .toDouble();
        targetRemaining = initialRemaining;
        targetId = await _consumableDao.addConsumable(
          ConsumablesCompanion.insert(
            manufacturer: tray.traySubBrands.isNotEmpty
                ? tray.traySubBrands
                : 'Bambu',
            model: tray.trayInfoIdx,
            materialType: Value(tray.trayType),
            colorHex: Value(
              '#${tray.trayColor.length >= 6 ? tray.trayColor.substring(0, 6) : 'FFFFFF'}',
            ),
            colorName: Value(_inferColorName(tray.trayColor)),
            totalGrams: Value(nominalGrams),
            remainingGrams: Value(initialRemaining),
            note: const Value('RFID 自动建档'),
          ),
        );
        if (personalOwnerAccount?.trim().isNotEmpty == true) {
          await _consumableDao.setOwnerAccount(targetId, personalOwnerAccount);
        }
        if (tray.normalizedTrayUuid.isNotEmpty) {
          await _consumableDao.updateTrayUuid(
            targetId,
            tray.normalizedTrayUuid,
          );
        }
        if (tray.normalizedTagUid.isNotEmpty) {
          await _consumableDao.setRfidSpoolBinding(
            targetId,
            tagUid: tray.normalizedTagUid,
            tagType: 'ams',
            cycle: 1,
            status: 'active',
          );
        }
      }
      if (targetId == null) {
        // Farm mode never creates or binds a personal inventory row. An
        // unmatched official RFID spool stays unbound until the farm-only
        // workflow can associate it with the correct warehouse SKU.
        continue;
      }
      if (!farmMode &&
          personalOwnerAccount != null &&
          !await _consumableDao.ensurePersonalConsumableAccess(
            targetId,
            ownerAccount: personalOwnerAccount,
            claimAnonymous: true,
          )) {
        continue;
      }

      // 物理 RFID 卷跨槽移动只转移槽位余额，不经过仓库，因此不会重复扣一卷。
      final source = sourceMatchesScope ? physicalSource : null;
      if (source != null) {
        if (!farmMode) {
          await PersonalSpoolHandoff(
            attachedDatabase,
          ).assertNotReservedElsewhere(targetId, printerId, tray.globalSlot);
          final old = currentConsumableId == null
              ? null
              : await _consumableDao.getById(currentConsumableId);
          if (old != null) {
            final channel = await (select(
              printerChannels,
            )..where((t) => t.id.equals(channelId))).getSingle();
            await PersonalSpoolHandoff(
              attachedDatabase,
            ).unload(channel, old, newConsumableId: targetId);
          }
        }
        if (currentConsumableId != null) {
          await _unloadChannelPreservingFarmStock(
            channelId,
            reason: 'RFID 卷换槽，归还目标槽旧卷',
          );
        }
        final sourceRemaining = source.read<double>('loaded_remaining_grams');
        final sourceWasMaintenancePaused =
            ChannelRollHoldState.fromDb(
              source.read<int?>('farm_roll_paused'),
            ) ==
            ChannelRollHoldState.maintenance;
        final movedRemaining = sourceWasMaintenancePaused
            ? sourceRemaining
            : (observedRemaining ?? sourceRemaining);
        await customUpdate(
          'UPDATE printer_channels SET consumable_id = NULL, '
          'loaded_remaining_grams = 0, loaded_spool_uid = NULL, '
          'farm_roll_paused = 0, updated_at = ? WHERE id = ?',
          variables: [
            Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
            Variable(source.read<int>('id')),
          ],
          updates: {printerChannels},
        );
        await customUpdate(
          'UPDATE printer_channels SET consumable_id = ?, '
          'loaded_remaining_grams = ?, loaded_spool_uid = ?, '
          'farm_roll_paused = 0, updated_at = ? WHERE id = ?',
          variables: [
            Variable(targetId),
            Variable(
              farmMode
                  ? movedRemaining.clamp(0.0, _farmRollGrams)
                  : movedRemaining,
            ),
            Variable(physicalIdentity),
            Variable(DateTime.now().millisecondsSinceEpoch ~/ 1000),
            Variable(channelId),
          ],
          updates: {printerChannels},
        );
        if (!farmMode &&
            !sourceWasMaintenancePaused &&
            observedRemaining != null) {
          await _consumableDao.updateRfidSync(
            consumableId: targetId,
            remainingGrams: observedRemaining,
          );
        }
        if (!farmMode) {
          final channel = await (select(
            printerChannels,
          )..where((t) => t.id.equals(channelId))).getSingle();
          await PersonalSpoolHandoff(attachedDatabase).record(
            channel,
            targetId,
            'spool_loaded',
            before: movedRemaining,
            after: movedRemaining,
          );
        }
        continue;
      }
      await changeRoll(
        channelId: channelId,
        newConsumableId: targetId,
        farmLoadAuthorization: FarmRollLoadAuthorization.rfidDetected,
        physicalSpoolUid: physicalIdentity,
        enforcePersonalOwner: !farmMode && personalOwnerAccount != null,
        personalOwnerAccount: personalOwnerAccount,
      );
      final nextRemaining =
          observedRemaining ?? (farmMode ? _farmRollGrams : targetRemaining!);
      final farmSlotUpdated = await syncFarmChannelLoadedRemaining(
        printerId: printerId,
        channelIndex: tray.globalSlot,
        remainingGrams: nextRemaining,
        expectedConsumableId: targetId,
      );
      if (!farmSlotUpdated) {
        await _consumableDao.updateRfidSync(
          consumableId: targetId,
          remainingGrams: nextRemaining,
        );
      }
    }
  }

  Future<Consumable?> _findBoundRfidConsumable(
    Iterable<String> identities, {
    required bool allowLegacyTrayUuid,
    String? personalOwnerAccount,
  }) async {
    for (final identity in identities) {
      // Desktop AMS sync is already operating on the user's local database;
      // unlike the phone write path it must see account-owned rows as well as
      // legacy unowned rows. This helper is intentionally unscoped and is not
      // exposed to inventory UI lists.
      final byPhysicalTag = personalOwnerAccount == null
          ? await _consumableDao.getAnyPersonalByRfidTagUid(identity)
          : await _consumableDao.getPersonalByRfidTagUid(
              identity,
              ownerAccount: personalOwnerAccount,
            );
      if (byPhysicalTag != null) {
        return byPhysicalTag;
      }
      if (allowLegacyTrayUuid) {
        final byTrayUuid = personalOwnerAccount == null
            ? await _consumableDao.getByTrayUuid(identity)
            : await _consumableDao.getPersonalByTrayUuid(
                identity,
                ownerAccount: personalOwnerAccount,
              );
        if (byTrayUuid != null) {
          final binding = await _consumableDao.getRfidSpoolBindingById(
            byTrayUuid.id,
          );
          if (binding?.tagUid.isNotEmpty != true || binding!.isActive) {
            return byTrayUuid;
          }
        }
      }
    }
    return null;
  }

  Future<QueryRow?> _findPhysicalSource(
    Iterable<String> identities, {
    required int excludedChannelId,
    String? personalOwnerAccount,
  }) async {
    for (final identity in identities) {
      final rows = await customSelect(
        'SELECT pc.id, pc.consumable_id, pc.loaded_remaining_grams, '
        'pc.farm_roll_paused, c.inventory_scope FROM printer_channels pc '
        'JOIN consumables c ON c.id = pc.consumable_id '
        'WHERE lower(trim(pc.loaded_spool_uid)) = lower(trim(?)) '
        "AND (c.inventory_scope = 'farm' OR coalesce(trim(c.rfid_tag_uid), '') = '' OR c.lifecycle_status = 'active') "
        'AND pc.farm_roll_paused != ? AND pc.id != ?',
        variables: [
          Variable(identity),
          Variable(ChannelRollHoldState.awaitingSelection.dbValue),
          Variable(excludedChannelId),
        ],
      ).get();
      for (final row in rows) {
        final id = row.read<int>('consumable_id');
        if (row.read<String>('inventory_scope') == farmInventoryScope ||
            personalOwnerAccount == null ||
            await _consumableDao.ensurePersonalConsumableAccess(
              id,
              ownerAccount: personalOwnerAccount,
            )) {
          return row;
        }
      }
    }
    return null;
  }

  static bool _matchesAmsIdentity(
    Iterable<String> candidates, {
    required Iterable<String?> values,
  }) {
    final normalizedCandidates = candidates
        .map(_canonicalAmsIdentity)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (normalizedCandidates.isEmpty) return false;
    for (final value in values) {
      if (value == null) continue;
      if (normalizedCandidates.contains(_canonicalAmsIdentity(value))) {
        return true;
      }
    }
    return false;
  }

  static String _canonicalAmsIdentity(String value) {
    final normalized = normalizeRfidTagUid(value);
    if (normalized.isEmpty || RegExp(r'^0+$').hasMatch(normalized)) return '';
    return normalized;
  }

  /// 按 SKU+颜色+材质模糊匹配未绑定耗材（拓竹原厂料首次装入场景）。
  Future<Consumable?> _fuzzyMatchConsumable(
    AmsTray tray, {
    required bool farmMode,
    String? personalOwnerAccount,
  }) async {
    final hex =
        '#${tray.trayColor.length >= 6 ? tray.trayColor.substring(0, 6) : 'FFFFFF'}';
    final rows = await customSelect(
      'SELECT c.* FROM consumables c '
      'WHERE (c.tray_uuid IS NULL OR c.tray_uuid = \'\') '
      'AND c.remaining_grams > 0 '
      'AND c.model = ? '
      'AND c.color_hex = ? '
      'AND c.material_type = ? '
      'AND c.inventory_scope = ? '
      '${farmMode ? 'AND c.remaining_grams >= $_farmRollGrams ' : 'AND c.id NOT IN (SELECT consumable_id FROM printer_channels WHERE consumable_id IS NOT NULL) '}',
      variables: [
        Variable<String>(tray.trayInfoIdx),
        Variable<String>(hex),
        Variable<String>(tray.trayType),
        Variable<String>(farmMode ? 'farm' : 'personal'),
      ],
    ).get();
    for (final row in rows) {
      final candidate = _consumableDao.rowToConsumable(row);
      if (farmMode ||
          personalOwnerAccount == null ||
          await _consumableDao.ensurePersonalConsumableAccess(
            candidate.id,
            ownerAccount: personalOwnerAccount,
          )) {
        return candidate;
      }
    }
    return null;
  }

  /// 从 RGB hex 推断中文颜色名（简单映射）。
  String _inferColorName(String rgbHex) {
    if (rgbHex.length < 6) return '未知颜色';
    final r = int.parse(rgbHex.substring(0, 2), radix: 16);
    final g = int.parse(rgbHex.substring(2, 4), radix: 16);
    final b = int.parse(rgbHex.substring(4, 6), radix: 16);
    // 简单颜色判定
    if (r > 220 && g > 220 && b > 220) return '白';
    if (r < 40 && g < 40 && b < 40) return '黑';
    if (r > 200 && g > 200 && b < 100) return '黄';
    if (r > 200 && g < 100 && b < 100) return '红';
    if (r < 100 && g > 200 && b < 100) return '绿';
    if (r < 100 && g < 100 && b > 200) return '蓝';
    if (r > 200 && g < 150 && b > 150) return '粉';
    if (r > 150 && g > 100 && b < 100) return '橙';
    if (r > 100 && g < 150 && b > 150) return '紫';
    if (r > 100 && g > 100 && b < 100) return '棕';
    return '自定义';
  }

  /// 更新打印机名称。
  Future<void> updatePrinterName(int id, String? name) async {
    await (update(printers)..where((t) => t.id.equals(id))).write(
      PrintersCompanion(name: Value(name), updatedAt: Value(DateTime.now())),
    );
  }

  /// 查询每个耗材当前被绑定到多少个通道。
  /// 用于选耗材时判断是否还可继续绑定（同卷耗材可绑多个通道，上限为库存卷数）。
  Future<Map<int, int>> getBoundConsumableCounts() async {
    final rows =
        await (select(printerChannels)
              ..where((t) => t.consumableId.isNotNull()))
            .map((t) => t.consumableId)
            .get();
    final counts = <int, int>{};
    for (final id in rows.whereType<int>()) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  /// 通道标签：A / B / C / D / E ...
  List<String> _channelLabels(int count) {
    return List.generate(count, (i) => String.fromCharCode(65 + i));
  }

  /// 把云端设备 upsert 到本地 printers 表。
  ///
  /// 云模式用户登录后拉取到的云端设备需要同步到本地，否则创建打印任务时
  /// 无法选到打印机（print_tasks.printer_id 引用本地 printers.id）。
  ///
  /// - serial 已存在：更新 name / model / updatedAt
  /// - serial 不存在：插入新打印机 + 写入 serial + 创建机型默认外挂料位
  ///
  /// **品牌映射**：云端 dev_product_name 返回英文（如 "A1"），但本地预设库
  /// 用中文品牌"拓竹"。这里统一映射成"拓竹"，保证图片能匹配上预设资源。
  /// 型号也做归一化：dev_product_name "A1 mini" → "A1mini"（对齐预设）。
  ///
  /// serial 列不在 drift 代码生成范围内（build_runner 不可用），
  /// 对它的读写用 raw SQL，其余字段走 drift API（自动处理 DateTime / 默认值）。
  Future<void> upsertCloudDevice(BambuCloudDevice device) async {
    if (device.devId.isEmpty) return;

    // 归一化品牌和型号，对齐本地预设库（PrinterPresets）
    final brand = _normalizeBrand(device.devProductName);
    final model = normalizeModel(device.devProductName);
    final feedSlots = _defaultExternalFeedSlots(brand, model);

    await transaction(() async {
      final existing = await customSelect(
        'SELECT id, name, brand, model FROM printers WHERE serial = ?',
        variables: [Variable(device.devId)],
      ).get();

      if (existing.isNotEmpty) {
        final row = existing.first;
        final id = row.read<int>('id');
        final currentName = row.read<String?>('name');
        final currentBrand = row.read<String>('brand');
        final currentModel = row.read<String>('model');
        if (currentName == device.name &&
            currentBrand == brand &&
            currentModel == model) {
          return;
        }
        await (update(printers)..where((t) => t.id.equals(id))).write(
          PrintersCompanion(
            name: Value(device.name),
            brand: Value(brand),
            model: Value(model),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return;
      }

      // 不存在：用 drift API 插入（自动处理 DateTime、默认值）
      final id = await into(printers).insert(
        PrintersCompanion.insert(
          brand: brand,
          model: model,
          channelCount: Value(feedSlots.length),
          name: Value(device.name),
        ),
      );
      // 用 raw SQL 写入 serial（该列不在 drift 代码生成范围内）
      await customUpdate(
        'UPDATE printers SET serial = ? WHERE id = ?',
        variables: [Variable(device.devId), Variable(id)],
      );
      await _insertFeedSlots(id, feedSlots);
    });
  }

  /// 把 LAN 连接配置同步到工作台打印机列表。
  ///
  /// 连接凭据仍只保存在 SharedPreferences；数据库仅保存可用于展示和任务关联的
  /// 设备身份。已存在的打印机不会重建通道，避免破坏耗材绑定。
  Future<void> upsertLanConnection(PrinterConnectionConfig config) async {
    if (config.mode != BambuConnectionMode.lan || config.serial.isEmpty) {
      return;
    }

    final rawModel = config.devProductName?.trim();
    final model = rawModel == null || rawModel.isEmpty
        ? '拓竹打印机'
        : normalizeModel(rawModel);
    final displayName = config.displayName?.trim();
    final feedSlots = _defaultExternalFeedSlots('拓竹', model);

    await transaction(() async {
      final existing = await customSelect(
        'SELECT id, name, brand, model FROM printers WHERE serial = ?',
        variables: [Variable(config.serial)],
      ).get();

      if (existing.isNotEmpty) {
        final row = existing.first;
        final id = row.read<int>('id');
        final currentName = row.read<String?>('name');
        final currentBrand = row.read<String>('brand');
        final currentModel = row.read<String>('model');
        final nextName = displayName != null && displayName.isNotEmpty
            ? displayName
            : currentName;
        final nextModel = rawModel != null && rawModel.isNotEmpty
            ? model
            : currentModel;
        if (currentName == nextName &&
            currentBrand == '拓竹' &&
            currentModel == nextModel) {
          return;
        }
        await (update(printers)..where((t) => t.id.equals(id))).write(
          PrintersCompanion(
            name: Value(nextName),
            model: Value(nextModel),
            brand: const Value('拓竹'),
            updatedAt: Value(DateTime.now()),
          ),
        );
        return;
      }

      final id = await into(printers).insert(
        PrintersCompanion.insert(
          brand: '拓竹',
          model: model,
          channelCount: Value(feedSlots.length),
          name: displayName == null || displayName.isEmpty
              ? const Value.absent()
              : Value(displayName),
        ),
      );
      await customUpdate(
        'UPDATE printers SET serial = ? WHERE id = ?',
        variables: [Variable(config.serial), Variable(id)],
      );
      await _insertFeedSlots(id, feedSlots);
    });
  }

  List<PrinterFeedSlotDefinition> _defaultExternalFeedSlots(
    String brand,
    String model,
  ) {
    final preset = PrinterPresets.findByModel(model, brand: brand);
    return externalFeedSlots(preset?.externalInputCount ?? 1);
  }

  /// 根据云端 dev_product_name 推断中文品牌（对齐 PrinterPresets）。
  /// 拓竹全系列都用 "拓竹"，未来支持其他品牌时在此扩展。
  static String _normalizeBrand(String devProductName) {
    // 拓竹型号：A1 / A1 mini / P1P / P1S / X1 / X1 Carbon / X1E / H2D 等
    final p = devProductName.toUpperCase();
    if (p.contains('A1') ||
        p.contains('P1') ||
        p.contains('P2') ||
        p.contains('X1') ||
        p.contains('X2') ||
        p.contains('H2') ||
        p.contains('A2')) {
      return '拓竹';
    }
    // 未知品牌 fallback：保留原值
    return devProductName;
  }

  /// 归一化型号名，对齐 PrinterPresets 中的 model 字段。
  ///
  /// **保留细分型号**：云端 dev_product_name 可能返回 "X1 Carbon" / "P1S" / "H2D" 等，
  /// 归一化后对齐预设库中的精确型号（X1C / P1S / H2D），不再归并为大类，
  /// 确保图片和型号显示精确匹配。
  ///
  /// 映射规则（大小写不敏感）：
  /// - "X1 Carbon" / "X1C" → X1C
  /// - "X1E" → X1E
  /// - "X2D" → X2D
  /// - "P1P" → P1P，"P1S" → P1S
  /// - "P2S" → P2S
  /// - "A1 mini" / "A1mini" → A1mini
  /// - "A1" → A1
  /// - "A2L" → A2L
  /// - "H2D" → H2D，"H2S" → H2S，"H2C" → H2C
  /// - 其他：原样返回
  static String normalizeModel(String devProductName) {
    return PrinterModelNormalizer.normalize(devProductName);
  }
}
