import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../mobile/ams_tag_template.dart';
import '../../mobile/mobile_inventory_sync.dart';
import '../../mobile/mobile_rfid_models.dart';
import '../../mobile/rfid_native_bridge.dart';
import 'desktop_rfid_bridge.dart';

enum RfidReceiptMode { individual, stock }

/// Contains inventory metadata only: no source dumps, keys or signatures.
class DesktopRfidQueueItem {
  DesktopRfidQueueItem({
    required this.id,
    required this.uid,
    required this.kind,
    required this.draft,
    required this.grams,
    required this.quantity,
    required this.mode,
    this.writeVerified = false,
    this.done = false,
    this.feedback = '待入库',
    this.syncPending = false,
  });
  final String id, uid, kind;
  final MobileConsumableDraft draft;
  final double grams;
  final int quantity;
  final RfidReceiptMode mode;
  final bool writeVerified;
  bool done, syncPending;
  String feedback;
  Map<String, Object> toJson() => {
    'id': id,
    'uid': uid,
    'kind': kind,
    'brand': draft.brand,
    'model': draft.model,
    'color': draft.color.toARGB32(),
    'colorName': draft.colorName,
    'grams': grams,
    'quantity': quantity,
    'mode': mode.name,
    'writeVerified': writeVerified,
    'done': done,
    'feedback': feedback,
    'syncPending': syncPending,
  };
  factory DesktopRfidQueueItem.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['id'] as String) ||
        value['uid'] is! String ||
        !RegExp(r'^[A-F0-9]{8}$').hasMatch(value['uid'] as String) ||
        !const ['cuid', 'fuid'].contains(value['kind']) ||
        !RfidReceiptMode.values.any((m) => m.name == value['mode'])) {
      throw const FormatException('待办记录损坏');
    }
    final draft = MobileConsumableDraft(
      brand: value['brand'] as String,
      model: value['model'] as String,
      color: Color(value['color'] as int),
      colorName: value['colorName'] as String,
    );
    final grams = (value['grams'] as num).toDouble();
    final quantity = value['quantity'] as int;
    DesktopRfidController.validateDraft(
      draft,
      grams,
      quantity,
      preserveExisting: true,
    );
    final mode = RfidReceiptMode.values.byName(value['mode'] as String);
    if (mode == RfidReceiptMode.individual && quantity != 1) {
      throw const FormatException('当前卷登记数量不正确');
    }
    return DesktopRfidQueueItem(
      id: value['id'] as String,
      uid: value['uid'] as String,
      kind: value['kind'] as String,
      draft: draft,
      grams: grams,
      quantity: quantity,
      mode: mode,
      writeVerified: value['writeVerified'] == true,
      done: value['done'] == true,
      syncPending: value['syncPending'] == true,
      feedback: value['done'] == true
          ? value['feedback'] as String
          : '上次待办 · 可继续入库',
    );
  }
}

abstract interface class DesktopRfidJournal {
  Future<List<DesktopRfidQueueItem>> load(String owner);
  Future<void> save(String owner, List<DesktopRfidQueueItem> items);
}

class PreferencesDesktopRfidJournal implements DesktopRfidJournal {
  String _key(String owner) =>
      'desktop_rfid_queue_v1_${sha256.convert(utf8.encode(owner))}';
  @override
  Future<List<DesktopRfidQueueItem>> load(String owner) async {
    final text = (await SharedPreferences.getInstance()).getString(_key(owner));
    if (text == null) return [];
    if (text.length > 256000) throw const FormatException('待办数据异常');
    final value = jsonDecode(text);
    if (value is! Map ||
        value['owner'] != owner ||
        value['items'] is! List ||
        (value['items'] as List).length > 100) {
      throw const FormatException('待办数据异常');
    }
    return [
      for (final item in value['items'] as List)
        DesktopRfidQueueItem.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
  }

  @override
  Future<void> save(String owner, List<DesktopRfidQueueItem> items) async {
    final data = jsonEncode({
      'owner': owner,
      'items': items.map((e) => e.toJson()).toList(),
    });
    if (!await (await SharedPreferences.getInstance()).setString(
      _key(owner),
      data,
    )) {
      throw StateError('本机待办保存失败');
    }
  }
}

/// The same DAO/API boundary as Android. Hardware verification and inventory
/// receipt are separate: a failed receipt never repeats a hardware write.
class DesktopRfidController extends ChangeNotifier {
  DesktopRfidController({
    required this.bridge,
    required this.sync,
    required this.journal,
    required this.owner,
    required this.isCurrent,
  }) {
    bridge.addListener(_changed);
    ready = _load();
  }
  final DesktopRfidBridge bridge;
  final MobileInventorySync sync;
  final DesktopRfidJournal journal;
  final String owner;
  final bool Function() isCurrent;
  late final Future<void> ready;
  final List<DesktopRfidQueueItem> _items = [];
  List<DesktopRfidQueueItem> get items => List.unmodifiable(_items);
  bool _disposed = false;
  bool working = false;
  bool saving = false;
  bool loaded = false;
  bool journalHealthy = true;
  String? message;
  DesktopRfidScan? target;
  AmsTagTemplate? template;
  bool get current => !_disposed && isCurrent();
  bool get busy => working || saving || bridge.busy || !loaded;
  int get pendingCount => _items.where((i) => !i.done).length;
  int get doneCount =>
      _items.where((i) => i.done).fold(0, (n, i) => n + i.quantity);
  void _changed() {
    // A target belongs to the reader session in which it was scanned. Never
    // carry it across a USB reconnect or a reader power/SPI interruption.
    if (!bridge.connected || !bridge.readerReady) target = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> _load() async {
    try {
      final saved = await journal.load(owner);
      if (current) _items.addAll(saved);
    } catch (_) {
      journalHealthy = false;
      message = '上次待办读取失败。为防重复入库，当前已暂停新增；请保留数据并检查本机存储';
    } finally {
      loaded = true;
      _changed();
    }
  }

  static void validateDraft(
    MobileConsumableDraft draft,
    double grams,
    int quantity, {
    bool preserveExisting = false,
  }) {
    if ([
          draft.brand,
          draft.model,
        ].any((s) => s.trim().isEmpty || s.trim().length > 64) ||
        draft.colorName.length > 64) {
      throw const DesktopRfidException(
        'invalid_draft',
        '请填写品牌和型号（各最多 64 字），颜色名称最多 64 字',
      );
    }
    if (!grams.isFinite ||
        grams <= 0 ||
        grams > (preserveExisting ? 100000 : 1000) ||
        quantity < 1 ||
        quantity > 100 ||
        (!preserveExisting && quantity > 1 && grams != 1000)) {
      throw const DesktopRfidException(
        'invalid_quantity',
        '资料卡整卷批次每卷 1000 g、数量 1–100；按余量或写卡登记当前卷时只登记一卷，范围 0–1000 g（不含 0）',
      );
    }
  }

  void _guard() {
    if (!current) {
      throw const DesktopRfidException('account_changed', '账号或工作台已切换，已停止本次操作');
    }
    if (busy) throw const DesktopRfidException('busy', '请等待当前操作完成');
    if (!journalHealthy) {
      throw const DesktopRfidException('journal_unavailable', '本机待办尚未恢复，已暂停新增');
    }
  }

  void selectTemplate(AmsTagTemplate value) {
    _guard();
    template = value;
    target = null;
    _changed();
  }

  void clearTemplate(String id) {
    if (template?.id == id) {
      template = null;
      target = null;
      _changed();
    }
  }

  Future<void> scanTarget() async {
    _guard();
    working = true;
    target = null;
    message = null;
    _changed();
    try {
      final result = await bridge.scan();
      if (!current) return;
      target = result;
      message = '已读取目标 UID ${result.uid}；卡型需根据购买信息确认，读取不会测试写入 UID';
    } finally {
      working = false;
      _changed();
    }
  }

  Future<AmsTagTemplate?> readSource() async {
    _guard();
    working = true;
    message = null;
    _changed();
    try {
      final value = await bridge.readTemplate();
      return current ? value : null;
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> enqueueScan({
    required MobileConsumableDraft draft,
    required double grams,
    required String kind,
    required bool typeConfirmed,
    required RfidReceiptMode mode,
    int quantity = 1,
  }) async {
    _guard();
    validateDraft(draft, grams, quantity);
    if (!typeConfirmed || !const ['cuid', 'fuid'].contains(kind)) {
      throw const DesktopRfidException(
        'type_required',
        '请确认使用的是 CUID/FUID；普通 S50 不能自动当作可改 UID 卡',
      );
    }
    if (mode == RfidReceiptMode.individual && quantity != 1) {
      throw const DesktopRfidException(
        'invalid_quantity',
        '写卡登记当前物理卷每次只登记一卷；批量补货请使用 CUID/FUID 资料卡模式',
      );
    }
    if (_items.length >= 100) {
      throw const DesktopRfidException('queue_full', '本批最多 100 条，请处理后开始新批次');
    }
    working = true;
    message = null;
    _changed();
    try {
      final tag = await bridge.scan();
      if (!current) return;
      // Just like Android batch scanning: read-only shape does not prove UID
      // writability. The user's carrier confirmation stays explicit.
      await _enqueue(
        DesktopRfidQueueItem(
          id: const Uuid().v4(),
          uid: tag.uid,
          kind: kind,
          draft: draft,
          grams: grams,
          quantity: quantity,
          mode: mode,
        ),
      );
      message = mode == RfidReceiptMode.stock
          ? '已读取资料卡并加入待办；确认保存前可取消，本次尚未增加库存'
          : '已加入当前卷待办；确认保存前尚未修改库存';
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> writeTarget({
    required MobileConsumableDraft draft,
    required double grams,
    required String kind,
    required bool confirmed,
  }) async {
    _guard();
    validateDraft(draft, grams, 1);
    final source = template;
    final scanned = target;
    if (source == null || scanned == null) {
      throw const DesktopRfidException('selection_required', '请先选择完整模板并读取目标卡');
    }
    if (_items.length >= 100 || _items.any((i) => i.uid == source.uid)) {
      throw const DesktopRfidException(
        'duplicate_uid',
        '此模板 UID 已在本批待办中；相同 UID 不能区分多张实体卡，请勿重复写入',
      );
    }
    working = true;
    message = null;
    _changed();
    try {
      await bridge.restore(
        source,
        targetKind: kind,
        expectedUid: scanned.uid,
        confirmed: confirmed,
      );
      if (!current) return;
      await _enqueue(
        DesktopRfidQueueItem(
          id: const Uuid().v4(),
          uid: source.uid,
          kind: kind,
          draft: draft,
          grams: grams,
          quantity: 1,
          mode: RfidReceiptMode.individual,
          writeVerified: true,
        ),
      );
      message = '64 块和真实 UID 已校验，待确认入库。AMS 实机兼容性仍需验证';
    } finally {
      target = null;
      working = false;
      _changed();
    }
  }

  Future<void> _enqueue(DesktopRfidQueueItem item) async {
    if (_items.any((i) => i.uid == item.uid)) {
      throw const DesktopRfidException(
        'duplicate_uid',
        '此 UID 已在本批中，已拦截重复。新到货请在本批完成后明确开始新批次',
      );
    }
    final next = [..._items, item];
    try {
      await journal.save(owner, next);
    } catch (_) {
      throw DesktopRfidException(
        'journal_failed',
        item.writeVerified
            ? '标签已校验，但待办保存失败；请保留此卡。不要重写，恢复存储后可读卡登记'
            : '本机待办保存失败，尚未入库',
      );
    }
    if (current) _items.add(item);
  }

  Future<void> commit() async {
    _guard();
    saving = true;
    message = null;
    _changed();
    try {
      for (final item in _items.where((i) => !i.done)) {
        if (!current) break;
        item.feedback = '保存中…';
        _changed();
        // Persist the stable receipt UUID before any database/network write.
        await journal.save(owner, _items);
        if (!current) break;
        try {
          if (item.mode == RfidReceiptMode.stock) {
            final stock = sync;
            if (stock is! MobileInventoryStockSync) {
              throw StateError('当前库存服务不支持同款多卷入库');
            }
            final result = await (stock as MobileInventoryStockSync)
                .receiveFromCard(
                  item.draft,
                  operationUid: item.id,
                  tagUid: item.uid,
                  tagType: item.kind,
                  quantity: item.quantity,
                  initialGrams: item.grams,
                );
            item.syncPending = result.syncPending;
            item.feedback = result.receipt.replayed
                ? '已核对上次入库 · 未重复新增'
                : '已入库 ${item.quantity} 卷';
          } else {
            final result = await sync.save(
              item.draft,
              tagId: item.uid,
              tagType: item.kind,
              initialGrams: item.grams,
            );
            item.syncPending = result.syncPending;
            item.feedback = result.requiresReplacement
                ? '历史标签 · 请到库存详情确认换卷（未新增）'
                : '已登记当前卷 · 同 UID 不重复新增';
          }
          item.done = true;
          if (item.syncPending) item.feedback += ' · 本机已保存，云端待同步';
        } catch (_) {
          item.feedback = '入库未完成 · 可重试，不会再次写卡';
        }
        await journal.save(owner, _items);
        _changed();
      }
      if (current) {
        message = pendingCount == 0
            ? '本批已处理完成；新到货请点击“开始新批次”'
            : '部分记录未完成，请检查登录或存储后重试待办';
      }
    } finally {
      saving = false;
      _changed();
    }
  }

  Future<void> remove(DesktopRfidQueueItem item) async {
    _guard();
    if (item.done) return; // Completed receipts remain deduplication evidence.
    final next = _items.where((i) => i.id != item.id).toList();
    await journal.save(owner, next);
    if (current) {
      _items.remove(item);
      _changed();
    }
  }

  Future<void> newBatch() async {
    _guard();
    if (pendingCount != 0) {
      throw const DesktopRfidException(
        'pending_items',
        '请先处理或移除待办，不会自动清空未完成记录',
      );
    }
    await journal.save(owner, []);
    if (current) {
      _items.clear();
      message = '新批次已开始';
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    bridge.removeListener(_changed);
    super.dispose();
  }
}
