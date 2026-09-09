import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/interaction_effects.dart';
import '../core/utils/color_utils.dart';
import '../data/external/slicer/material_catalog_service.dart';
import '../features/color_picker/color_picker_panel.dart';
import '../widgets/filament_spool_icon.dart';
import 'ams_tag_template.dart';
import 'ams_template_repository.dart';
import 'ams_template_picker.dart';
import 'mobile_rfid_models.dart';
import 'mobile_inventory_sync.dart';
import 'mobile_visual_theme.dart';
import 'mobile_rfid_tag_repository.dart';
import 'rfid_native_bridge.dart';

/// The focused mobile extension of the desktop inventory app.
///
/// It intentionally has one job: collect the desktop-compatible spool fields
/// and hand them to the injected NFC writer, then to the injected inventory
/// sync adapter. No AMS-reading workflow is exposed here.
class MobileRfidWriterPage extends StatefulWidget {
  final RfidNativeBridge? nfc;
  final MobileInventorySync sync;
  final Future<List<String>> Function()? loadMaterials;
  final String? accountLabel;
  final String? accountIdentity;
  final String? ownerAccount;
  final void Function(BuildContext context)? onAccountTap;
  final MobileRfidTagRepository? tagRepository;
  final AmsTemplateRepository? amsTemplateRepository;

  /// A kept-alive tab must not keep waiting for a physical tag off screen.
  /// This is independent of animation preferences and does not poll NFC.
  final bool isActive;

  /// App-bar title supplied by the host shell. Desktop-compatible callers can
  /// keep the original "写入 RFID" title while the Android home surface uses
  /// a clearer AMS registration label.
  final String pageTitle;

  const MobileRfidWriterPage({
    super.key,
    this.nfc,
    this.sync = const NoopMobileInventorySync(),
    this.loadMaterials,
    this.accountLabel,
    this.accountIdentity,
    this.ownerAccount,
    this.onAccountTap,
    this.tagRepository,
    this.amsTemplateRepository,
    this.isActive = true,
    this.pageTitle = '写入 RFID',
  });

  @override
  State<MobileRfidWriterPage> createState() => _MobileRfidWriterPageState();
}

class _MobileRfidWriterPageState extends State<MobileRfidWriterPage>
    with WidgetsBindingObserver {
  late RfidNativeBridge _nfc;
  final _brandController = TextEditingController();
  final _initialWeightController = TextEditingController(text: '1000');
  bool _registerRemainder = false;
  final _materialSearchController = TextEditingController();
  final _brandFocus = FocusNode();

  Color _color = Colors.white;
  String _colorName = '';
  String _material = '';
  List<String> _materials = const [];
  bool _materialsLoading = true;
  bool _nfcStateKnown = false;
  bool _nfcAvailable = false;
  bool _nfcEnabled = false;
  bool _checkingNfc = false;
  Future<bool>? _nfcCheckFuture;
  bool _writing = false;
  bool _reading = false;
  bool _savingInventory = false;
  bool _loadingTemplates = false;
  bool _selectingAmsTemplate = false;
  AmsTagTemplate? _amsTemplate;
  String? _nfcProgress;
  AmsTemplateRepository get _amsTemplates =>
      widget.amsTemplateRepository ??
      const MethodChannelAmsTemplateRepository();
  String? _error;
  RfidWriteSuccess? _lastWrite;
  String? _inventoryFeedback;
  bool _inventorySyncPending = false;
  int _accountGeneration = 0;
  int _nfcOperationGeneration = 0;
  int _templatePickerGeneration = 0;
  final _templateAccountRevision = ValueNotifier<int>(0);
  int _catalogGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final bridge = widget.nfc ?? MethodChannelRfidNativeBridge();
    _nfc = bridge;
    _loadMaterialCatalog();
  }

  @override
  void didUpdateWidget(covariant MobileRfidWriterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      unawaited(_cancelOperation());
    }
    if (oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.ownerAccount != widget.ownerAccount) {
      _accountGeneration += 1;
      _templateAccountRevision.value = _accountGeneration;
      _lastWrite = null;
      _inventoryFeedback = null;
      _amsTemplate = null;
      if (_writing || _reading) unawaited(_cancelOperation());
    }
    if (!_writing && !_reading && oldWidget.nfc != widget.nfc) {
      final bridge = widget.nfc ?? MethodChannelRfidNativeBridge();
      _nfc = bridge;
    }
    // A successful sohun login changes the catalog callback from the local
    // fallback to the account-backed desktop model list.
    if (oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.loadMaterials != widget.loadMaterials) {
      _materialsLoading = true;
      _loadMaterialCatalog();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nfcOperationGeneration += 1;
    unawaited(_cancelNativeWrite());
    _brandController.dispose();
    _initialWeightController.dispose();
    _materialSearchController.dispose();
    _brandFocus.dispose();
    _templateAccountRevision.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        (_writing || _reading)) {
      unawaited(_cancelOperation());
    }
    // NFC is an on-demand capability. Do not query the adapter merely because
    // the app returned to the foreground; the user may never use an NFC
    // feature during this session. The next explicit write/read/refresh action
    // performs a fresh check instead.
  }

  Future<void> _cancelNativeWrite() async {
    try {
      await _nfc.cancel();
    } catch (_) {
      // The native activity may already be gone during route disposal.
    }
  }

  Future<void> _loadMaterialCatalog() async {
    final generation = ++_catalogGeneration;
    try {
      final values =
          await (widget.loadMaterials ?? MaterialCatalogService.load)();
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _materials = values;
        _materialsLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _materials = MaterialCatalogService.fallbackMaterials;
        _materialsLoading = false;
      });
    }
  }

  Future<bool> _refreshNfcState() {
    final inFlight = _nfcCheckFuture;
    if (inFlight != null) return inFlight;

    if (mounted) setState(() => _checkingNfc = true);
    late final Future<bool> check;
    check = () async {
      try {
        final available = await _nfc.isAvailable();
        final enabled = available && await _nfc.isEnabled();
        if (!mounted) return false;
        setState(() {
          _nfcStateKnown = true;
          _nfcAvailable = available;
          _nfcEnabled = enabled;
          _checkingNfc = false;
        });
        return available && enabled;
      } catch (_) {
        if (!mounted) return false;
        setState(() {
          _nfcStateKnown = true;
          _nfcAvailable = false;
          _nfcEnabled = false;
          _checkingNfc = false;
        });
        return false;
      }
    }();
    _nfcCheckFuture = check;
    return check.whenComplete(() {
      if (identical(_nfcCheckFuture, check)) {
        _nfcCheckFuture = null;
        if (mounted && _checkingNfc) setState(() => _checkingNfc = false);
      }
    });
  }

  Future<bool> _ensureNfcReady({required String action}) async {
    final ready = await _refreshNfcState();
    if (ready || !mounted) return ready;
    final message = !_nfcAvailable
        ? '此设备不支持 NFC，无法$action'
        : '请在系统设置中开启 NFC 后再$action';
    _showMessage(message, error: true);
    return false;
  }

  Future<void> _pickSavedTemplate() async {
    final repository = widget.tagRepository;
    if (repository == null || _loadingTemplates || _writing || _reading) return;
    final generation = _accountGeneration;
    final owner = widget.ownerAccount ?? '';
    setState(() => _loadingTemplates = true);
    try {
      final groups = await Future.wait([
        repository.list(ownerAccount: owner, profile: 'ams', limit: 500),
        repository.listInventoryTagBindings(ownerAccount: owner, limit: 500),
      ]);
      if (!mounted || generation != _accountGeneration) return;
      final unique = <String, RfidTagRecord>{};
      for (final record in groups.expand((group) => group)) {
        if (!record.succeeded ||
            !record.isConsumableTagRecord ||
            record.brand.trim().isEmpty ||
            record.model.trim().isEmpty ||
            !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(record.colorHex)) {
          continue;
        }
        final key = jsonEncode([
          record.brand.trim(),
          record.model.trim(),
          record.colorHex.toUpperCase(),
          record.colorName?.trim() ?? '',
        ]);
        unique.putIfAbsent(key, () => record);
      }
      final records = unique.values.toList();
      final selected = await showModalBottomSheet<RfidTagRecord>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('复用耗材模板', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('只复用品牌、型号和颜色；兼容标签身份由所选完整模板决定。'),
                const SizedBox(height: 12),
                Expanded(
                  child: records.isEmpty
                      ? const Center(child: Text('暂无模板，成功写入后会自动保存'))
                      : ListView.builder(
                          itemCount: records.length,
                          itemBuilder: (context, index) {
                            final record = records[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: FilamentSpoolIcon(
                                color: ColorUtils.fromHex(record.colorHex),
                                size: 42,
                              ),
                              title: Text(
                                '${record.brand} · ${record.model}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                record.colorName?.trim().isNotEmpty == true
                                    ? '${record.colorName} · ${record.colorHex}'
                                    : record.colorHex,
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.of(context).pop(record),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
      if (!mounted || generation != _accountGeneration || selected == null) {
        return;
      }
      setState(() {
        _brandController.text = selected.brand;
        _material = selected.model;
        _color = ColorUtils.fromHex(selected.colorHex);
        _colorName = selected.colorName ?? '';
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _accountGeneration) {
        _showMessage('模板加载失败，请稍后重试', error: true);
      }
    } finally {
      if (mounted) setState(() => _loadingTemplates = false);
    }
  }

  MobileConsumableDraft? _buildDraft() {
    final brand = _brandController.text.trim();
    if (brand.isEmpty) {
      setState(() => _error = '请输入品牌');
      _brandFocus.requestFocus();
      return null;
    }
    if (_material.isEmpty) {
      setState(() => _error = '请选择耗材型号');
      return null;
    }
    final initialGrams = _registerRemainder
        ? double.tryParse(_initialWeightController.text.trim())
        : 1000.0;
    if (initialGrams == null ||
        !initialGrams.isFinite ||
        initialGrams <= 0 ||
        initialGrams > 1000) {
      setState(() => _error = '请输入大于 0 且不超过 1000 g 的剩余克数');
      return null;
    }
    setState(() => _error = null);
    return MobileConsumableDraft(
      brand: brand,
      model: _material,
      color: _color,
      colorName: _colorName,
    );
  }

  Future<void> _pickAmsTemplate() async {
    if (_writing || _reading || _selectingAmsTemplate) return;
    final generation = _accountGeneration;
    final pickerGeneration = ++_templatePickerGeneration;
    final owner = widget.ownerAccount ?? '';
    setState(() => _selectingAmsTemplate = true);
    try {
      final selected = await showAmsTemplatePicker(
        context,
        repository: _amsTemplates,
        ownerAccount: owner,
        accountRevision: _templateAccountRevision,
        onDeleted: (id) {
          if (mounted &&
              generation == _accountGeneration &&
              _amsTemplate?.id == id) {
            setState(() => _amsTemplate = null);
          }
        },
      );
      if (!mounted ||
          generation != _accountGeneration ||
          pickerGeneration != _templatePickerGeneration ||
          selected == null) {
        return;
      }
      if (selected.readFromTag) {
        await _readAmsSource();
      } else {
        setState(() {
          _amsTemplate = selected.template;
          _error = null;
        });
      }
    } finally {
      if (mounted && pickerGeneration == _templatePickerGeneration) {
        setState(() => _selectingAmsTemplate = false);
      }
    }
  }

  Future<void> _readAmsSource() async {
    if (!widget.isActive || _savingInventory) return;
    final bridge = _nfc;
    if (bridge is! AmsTemplateNfc) {
      _showMessage('当前设备未提供完整源标签读取服务', error: true);
      return;
    }
    final generation = _accountGeneration;
    final operationGeneration = ++_nfcOperationGeneration;
    final owner = widget.ownerAccount ?? '';
    final repository = _amsTemplates;
    if (!await _ensureNfcReady(action: '读取源标签') ||
        !mounted ||
        !widget.isActive ||
        generation != _accountGeneration ||
        operationGeneration != _nfcOperationGeneration) {
      return;
    }
    setState(() {
      _reading = true;
      _nfcProgress = '请贴近可被 AMS 识别的源标签';
      _error = null;
    });
    try {
      final result = await (bridge as AmsTemplateNfc).readAmsTemplate();
      if (!mounted ||
          generation != _accountGeneration ||
          operationGeneration != _nfcOperationGeneration) {
        return;
      }
      if (result is AmsTemplateReadSuccess) {
        await repository.save(result.template, ownerAccount: owner);
        if (!mounted ||
            generation != _accountGeneration ||
            operationGeneration != _nfcOperationGeneration) {
          return;
        }
        setState(() => _amsTemplate = result.template);
        _showMessage('完整模板已加密保存在本机，可重复使用；未新增耗材库存');
      } else if (result is AmsTemplateReadFailure) {
        _showMessage(result.message, error: true);
      }
    } catch (_) {
      if (mounted &&
          generation == _accountGeneration &&
          operationGeneration == _nfcOperationGeneration) {
        _showMessage('源模板读取或本机加密保存失败，请重试', error: true);
      }
    } finally {
      if (mounted && operationGeneration == _nfcOperationGeneration) {
        setState(() {
          _reading = false;
          _nfcProgress = null;
        });
      }
    }
  }

  Future<void> _write() async {
    if (!widget.isActive ||
        _savingInventory ||
        _writing ||
        _reading ||
        _selectingAmsTemplate ||
        _checkingNfc) {
      return;
    }
    final draft = _buildDraft();
    if (draft == null) return;
    final initialGrams = _registerRemainder
        ? double.parse(_initialWeightController.text.trim())
        : 1000.0;
    final writeGeneration = _accountGeneration;
    final operationGeneration = ++_nfcOperationGeneration;
    final writeSync = widget.sync;
    final selectedTemplate = _amsTemplate;
    String? targetKind;
    if (selectedTemplate == null) {
      setState(() => _error = '请先选择兼容标签模板');
      return;
    }
    if (_nfc is! AmsTemplateNfc) {
      _showMessage('当前设备未提供兼容模板写入服务，未写入标签', error: true);
      return;
    }
    setState(() => _selectingAmsTemplate = true);
    try {
      targetKind = await confirmAmsTemplateRestore(context, selectedTemplate);
    } finally {
      if (mounted) setState(() => _selectingAmsTemplate = false);
    }
    if (targetKind == null ||
        !mounted ||
        !widget.isActive ||
        writeGeneration != _accountGeneration ||
        operationGeneration != _nfcOperationGeneration) {
      return;
    }
    if (!await _ensureNfcReady(action: '写入') ||
        !mounted ||
        !widget.isActive ||
        writeGeneration != _accountGeneration ||
        operationGeneration != _nfcOperationGeneration) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _writing = true;
      _lastWrite = null;
      _inventoryFeedback = null;
      _nfcProgress = '请贴近目标标签并保持不动';
    });
    late final RfidWriteResult result;
    try {
      result = await (_nfc as AmsTemplateNfc).restoreAmsTemplate(
        selectedTemplate,
        targetKind: targetKind,
        allowUidChange: true,
        onProgress: (state) {
          if (!mounted ||
              !_writing ||
              writeGeneration != _accountGeneration ||
              operationGeneration != _nfcOperationGeneration) {
            return;
          }
          setState(
            () => _nfcProgress = state == 'awaiting_reselect'
                ? '请将标签移开，再贴回手机以验证新 UID'
                : state == 'verifying'
                ? '正在回读校验，请保持标签不动'
                : '正在恢复完整模板，请保持标签不动',
          );
        },
      );
    } catch (_) {
      if (!mounted || operationGeneration != _nfcOperationGeneration) return;
      setState(() => _writing = false);
      _showMessage('NFC 写入失败；未完成校验的标签请勿放入 AMS', error: true);
      return;
    }
    if (!mounted || operationGeneration != _nfcOperationGeneration) return;
    if (result is RfidWriteSuccess) {
      if (result.tagType?.trim().toLowerCase() !=
              targetKind.trim().toLowerCase() ||
          result.verified != true ||
          result.blocksVerified != 64 ||
          result.tagId?.toUpperCase() != selectedTemplate.uid.toUpperCase() ||
          result.amsCompatibility != 'template_restored_unverified') {
        setState(() => _writing = false);
        _showMessage('完整模板或真实 UID 尚未校验通过，未加入库存', error: true);
        return;
      }
      var syncPending = false;
      late MobileInventorySaveResult saved;
      if (writeGeneration != _accountGeneration) {
        setState(() => _writing = false);
        _showMessage('登录账号已切换，本次写入未加入耗材库', error: true);
        return;
      }
      setState(() {
        _savingInventory = true;
        _nfcProgress = '标签已校验，正在保存耗材库存';
      });
      try {
        saved = await writeSync.save(
          draft,
          tagId: result.tagId,
          tagType: result.tagType,
          initialGrams: initialGrams,
        );
        syncPending = saved.syncPending;
        if (writeGeneration != _accountGeneration) {
          throw const MobileInventoryAccountChangedException();
        }
        await _recordWrite(
          result,
          draft,
          inventoryUid: saved.inventoryUid,
          cycle: saved.rfidTagCycle,
        );
        if (writeGeneration != _accountGeneration) {
          throw const MobileInventoryAccountChangedException();
        }
        if (!saved.requiresReplacement) {
          await _recordBinding(
            tagUid: result.tagId,
            inventoryUid: saved.inventoryUid,
            cycle: saved.rfidTagCycle,
            tagType: result.tagType,
            technology: result.technology,
            profile: 'ams',
            draft: draft,
            message: saved.createdNewCycle ? '已创建新耗材卷' : '已登记当前耗材卷',
          );
        }
        if (widget.tagRepository != null) {
          syncPending = await synchronizeMobileAuditRecords(
            writeSync,
            syncPending: syncPending,
          );
        }
        if (writeGeneration != _accountGeneration) {
          throw const MobileInventoryAccountChangedException();
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _writing = false;
            _savingInventory = false;
          });
          _showMessage('标签已写入，但库存同步失败：$error', error: true);
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _writing = false;
        _savingInventory = false;
        _lastWrite = result as RfidWriteSuccess;
        _inventorySyncPending = syncPending;
        _inventoryFeedback = _saveFeedback(saved, syncPending: syncPending);
      });
      _showMessage(
        saved.requiresReplacement
            ? '标签已写入；第 ${saved.rfidTagCycle} 卷已结束，请在库存详情确认换入新卷后再创建下一周期'
            : syncPending
            ? '标签和本机库存已保存；云端待同步，请联网后刷新库存'
            : 'CUID/FUID 已写入并登记当前卷；同一资料卡可在库存页再次读取并批量加库存',
      );
    } else if (result is RfidWriteFailure) {
      setState(() {
        _writing = false;
        _lastWrite = null;
      });
      _showMessage(result.message, error: true);
    }
  }

  Future<void> _cancelOperation({bool showFeedback = false}) async {
    if (_savingInventory) return;
    // Native cancellation is best effort: a success/progress event may
    // already be queued. Invalidate it before awaiting the native bridge.
    final cancelledGeneration = ++_nfcOperationGeneration;
    if (!_writing && !_reading) return;
    final wasReading = _reading;
    if (wasReading) _templatePickerGeneration += 1;
    try {
      await _nfc.cancel();
    } catch (_) {
      // Native OPERATION_NOT_FOUND is an idempotent cancellation outcome.
    } finally {
      if (mounted &&
          !_savingInventory &&
          cancelledGeneration == _nfcOperationGeneration) {
        setState(() {
          _writing = false;
          _reading = false;
          _nfcProgress = null;
          if (wasReading) _selectingAmsTemplate = false;
        });
        if (showFeedback) {
          _showMessage(wasReading ? '已取消读取' : '已取消等待');
        }
      }
    }
  }

  Future<void> _recordWrite(
    RfidWriteSuccess result,
    MobileConsumableDraft draft, {
    String? inventoryUid,
    int? cycle,
  }) async {
    final repository = widget.tagRepository;
    final tagUid = result.tagId?.trim();
    if (repository == null || tagUid == null || tagUid.isEmpty) return;
    await repository.recordWrite(
      tagUid: tagUid,
      tagType: result.tagType,
      technology: result.technology,
      profile: 'ams',
      inventoryUid: inventoryUid,
      ownerAccount: widget.ownerAccount,
      brand: draft.brand,
      model: draft.model,
      colorHex: draft.colorHex,
      colorName: draft.colorName,
      bytesWritten: result.bytesWritten,
      blocksWritten: result.blocksWritten,
      blocksVerified: result.blocksVerified,
      verified: result.verified == true,
      message: cycle == null
          ? result.amsCompatibility
          : '${result.amsCompatibility} · 标签周期 $cycle'.trim(),
    );
  }

  String _saveFeedback(
    MobileInventorySaveResult saved, {
    required bool syncPending,
  }) {
    if (syncPending) return '已保存到本机 · 云端待同步';
    if (saved.requiresReplacement) {
      return '标签已处理 · 请在库存详情确认换卷';
    }
    return '已保存到耗材库';
  }

  Future<void> _recordBinding({
    required String? tagUid,
    required String inventoryUid,
    required int cycle,
    required String? tagType,
    required String? technology,
    required String profile,
    required MobileConsumableDraft draft,
    required String message,
  }) async {
    final repository = widget.tagRepository;
    final uid = tagUid?.trim();
    if (repository == null ||
        uid == null ||
        uid.isEmpty ||
        inventoryUid.isEmpty) {
      return;
    }
    await repository.recordBinding(
      tagUid: uid,
      inventoryUid: inventoryUid,
      ownerAccount: widget.ownerAccount,
      tagType: tagType,
      technology: technology,
      profile: profile,
      brand: draft.brand,
      model: draft.model,
      colorHex: draft.colorHex,
      colorName: draft.colorName,
      cycle: cycle,
      message: message,
    );
  }

  Future<void> _pickMaterial() async {
    _materialSearchController.clear();
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _MaterialPickerSheet(
        materials: _materials,
        controller: _materialSearchController,
      ),
    );
    if (selected != null && mounted) setState(() => _material = selected);
  }

  Future<void> _pickColor() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await ColorPickerPanel.show(
      context,
      initial: _color,
      initialName: _colorName,
      compact: true,
    );
    if (result != null && mounted) {
      setState(() {
        _color = result.color;
        _colorName = result.name;
      });
    }
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? AppColors.danger : AppColors.textPrimary,
        ),
      );
  }

  Future<void> _showRegistrationHelp() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showMobileGlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('登记帮助', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              const _RegistrationHelpItem(
                title: '先选模板，再填耗材',
                body:
                    '仅用于 CUID / FUID。选择、导入或读取完整源标签模板；品牌、型号和颜色保存至 Sohun，标签保留源模板参数。AMS 识别仍需实机验证。',
              ),
              const _RegistrationHelpItem(
                title: '每次登记当前 1 卷',
                body: '整卷按 1000 g 登记；余料填写实际剩余克数，不超过 1000 g。写入与回读校验通过后才保存库存。',
              ),
              const _RegistrationHelpItem(
                title: '后续到货，去库存批量添加',
                body: '同一张资料卡可重复使用。在库存页读取标签并选择新增卷数，取消不增加库存；无需重复写卡。',
              ),
              const _RegistrationHelpItem(
                title: '登录后同步个人库',
                body: '未登录时保存在本机。云端待同步时，联网后到库存页下拉刷新，无需重复写卡。',
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _consumableFields() {
    final enabled =
        !_writing &&
        !_reading &&
        !_savingInventory &&
        !_selectingAmsTemplate &&
        !_checkingNfc;
    return MobileGlassSurface(
      key: const ValueKey('mobile-registration-form'),
      padding: const EdgeInsets.all(14),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '耗材信息',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.tagRepository != null)
                IconButton(
                  onPressed: enabled && !_loadingTemplates
                      ? _pickSavedTemplate
                      : null,
                  tooltip: '复用耗材模板',
                  icon: const Icon(Icons.bookmarks_outlined, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final brand = TextField(
                key: const ValueKey('mobile-registration-brand'),
                enabled: enabled,
                controller: _brandController,
                focusNode: _brandFocus,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '品牌',
                  hintText: '输入品牌',
                ),
              );
              final material = _SelectionField(
                label: '耗材型号',
                value: _material,
                placeholder: _materialsLoading ? '加载中…' : '选择型号',
                onTap: enabled && !_materialsLoading ? _pickMaterial : null,
              );
              if (constraints.maxWidth >= 320 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 18) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: brand),
                    const SizedBox(width: 10),
                    Expanded(child: material),
                  ],
                );
              }
              return Column(
                children: [brand, const SizedBox(height: 10), material],
              );
            },
          ),
          const SizedBox(height: 10),
          _ColorField(
            color: _color,
            name: _colorName,
            onTap: enabled ? _pickColor : null,
          ),
          const SizedBox(height: 14),
          _registrationAmount(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final statusColor = !_nfcStateKnown
        ? AppColors.info
        : (!_nfcAvailable || !_nfcEnabled)
        ? AppColors.warning
        : AppColors.success;
    final statusText = !_nfcStateKnown
        ? '检查 NFC'
        : (!_nfcAvailable ? 'NFC 不可用' : (_nfcEnabled ? 'NFC 已就绪' : 'NFC 未开启'));

    return MobileScaffold(
      appBar: AppBar(
        flexibleSpace: const MobileGlassBar(),
        title: Text(widget.pageTitle),
        actions: [
          IconButton(
            onPressed: _writing || _reading || _savingInventory
                ? null
                : _showRegistrationHelp,
            tooltip: '登记帮助',
            icon: const Icon(Icons.help_outline_rounded),
          ),
          if (widget.onAccountTap != null)
            IconButton(
              onPressed: () => widget.onAccountTap!(context),
              tooltip: widget.accountLabel == null ? '登录 sohun' : '账号设置',
              icon: Icon(
                widget.accountLabel == null
                    ? Icons.person_outline_rounded
                    : Icons.account_circle_outlined,
              ),
            ),
          if (widget.accountLabel != null && widget.onAccountTap == null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: Text(
                    widget.accountLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 28).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _NfcStatus(
                    color: statusColor,
                    text: statusText,
                    checking: _checkingNfc,
                    onRefresh:
                        _checkingNfc || _writing || _reading || _savingInventory
                        ? null
                        : () => _refreshNfcState(),
                  ),
                  const SizedBox(height: 4),
                  ...[
                    MobileGlassSurface(
                      key: const ValueKey('mobile-registration-template'),
                      padding: const EdgeInsets.all(14),
                      onTap:
                          _writing ||
                              _reading ||
                              _selectingAmsTemplate ||
                              _savingInventory
                          ? null
                          : _pickAmsTemplate,
                      child: Row(
                        children: [
                          const Icon(Icons.nfc_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '兼容标签模板',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  _amsTemplate == null
                                      ? '选择模板'
                                      : _amsTemplate!.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _consumableFields(),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: _writing || _reading ? 82 : 12,
                    ),
                    child: AnimatedSwitcher(
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 260),
                      ),
                      child: (_writing || _reading)
                          ? _NfcPulseIndicator(
                              key: ValueKey(_reading ? 'reading' : 'writing'),
                              label:
                                  _nfcProgress ??
                                  (_reading ? '正在读取标签' : '等待标签靠近'),
                              animate: AppMotion.enabled(context),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 50),
                    child: FilledButton.icon(
                      key: const ValueKey('mobile-registration-submit'),
                      onPressed:
                          _writing ||
                              _reading ||
                              _savingInventory ||
                              _selectingAmsTemplate ||
                              _checkingNfc
                          ? null
                          : _write,
                      icon: _writing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.nfc_rounded),
                      label: Text(
                        _savingInventory
                            ? '正在保存库存…'
                            : _writing
                            ? '等待标签…'
                            : '靠近标签并写入',
                      ),
                    ),
                  ),
                  if (!_writing && !_reading && _lastWrite == null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.accountLabel?.trim().isNotEmpty == true
                          ? '登记 1 卷 · 登录账号的个人库'
                          : '登记 1 卷 · 保存在本机',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if ((_writing || _reading) && !_savingInventory) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => _cancelOperation(showFeedback: true),
                      icon: const Icon(Icons.close_rounded),
                      label: Text(_reading ? '取消读取' : '取消等待'),
                    ),
                  ],
                  AnimatedSize(
                    duration: AppMotion.duration(
                      context,
                      const Duration(milliseconds: 260),
                    ),
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      key: const ValueKey('mobile-operation-result'),
                      duration: AppMotion.duration(
                        context,
                        const Duration(milliseconds: 260),
                      ),
                      child: _lastWrite != null
                          ? Padding(
                              key: ObjectKey(_lastWrite),
                              padding: const EdgeInsets.only(top: 16),
                              child: Semantics(
                                liveRegion: true,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (_inventoryFeedback != null) ...[
                                      Text(
                                        _inventoryFeedback!,
                                        style: TextStyle(
                                          color: _inventorySyncPending
                                              ? AppColors.warning
                                              : textPrimary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (_inventorySyncPending)
                                        Text(
                                          '到库存页下拉同步，无需重写标签。',
                                          style: TextStyle(
                                            color: textSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                      const SizedBox(height: 8),
                                    ],
                                    _WriteResultBanner(
                                      key: const ValueKey(
                                        'mobile-write-result-content',
                                      ),
                                      result: _lastWrite!,
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('empty-result'),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _registrationAmount() {
    final enabled =
        !_writing &&
        !_reading &&
        !_savingInventory &&
        !_selectingAmsTemplate &&
        !_checkingNfc;
    Widget modeButton(bool remainder, String label) {
      final selected = _registerRemainder == remainder;
      final onPressed = enabled
          ? () => setState(() {
              _registerRemainder = remainder;
              _error = null;
            })
          : null;
      final style = ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge,
        ),
      );
      return Semantics(
        key: ValueKey(
          remainder
              ? 'mobile-registration-remnant'
              : 'mobile-registration-whole',
        ),
        selected: selected,
        child: selected
            ? FilledButton(
                onPressed: onPressed,
                style: style,
                child: Text(label),
              )
            : OutlinedButton(
                onPressed: onPressed,
                style: style,
                child: Text(label),
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            const Text('当前卷'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                modeButton(false, '整卷'),
                const SizedBox(width: 8),
                modeButton(true, '余料'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedSize(
          duration: AppMotion.duration(
            context,
            const Duration(milliseconds: 220),
          ),
          alignment: Alignment.topCenter,
          child: _registerRemainder
              ? TextField(
                  key: const ValueKey('rfid-initial-grams'),
                  controller: _initialWeightController,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '剩余克数（g）',
                    suffixText: 'g',
                  ),
                )
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '1 卷 · 1000 g',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        ),
      ],
    );
  }
}

class _NfcStatus extends StatelessWidget {
  final Color color;
  final String text;
  final bool checking;
  final VoidCallback? onRefresh;

  const _NfcStatus({
    required this.color,
    required this.text,
    required this.checking,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        Text('CUID / FUID', style: Theme.of(context).textTheme.labelMedium),
        Tooltip(
          message: '重新检查 NFC',
          child: TextButton.icon(
            key: const ValueKey('mobile-registration-nfc'),
            onPressed: onRefresh,
            style: TextButton.styleFrom(
              foregroundColor: color,
              textStyle: Theme.of(context).textTheme.labelMedium,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: checking
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : const Icon(Icons.nfc_rounded, size: 16),
            label: Semantics(
              liveRegion: true,
              child: Text(checking ? '检查中…' : text),
            ),
          ),
        ),
      ],
    );
  }
}

/// A compact NFC activity animation. The parent has a stable minimum height,
/// but can grow for system text scaling instead of clipping its status label.
class _NfcPulseIndicator extends StatefulWidget {
  const _NfcPulseIndicator({
    super.key,
    required this.label,
    required this.animate,
  });

  final String label;
  final bool animate;

  @override
  State<_NfcPulseIndicator> createState() => _NfcPulseIndicatorState();
}

class _NfcPulseIndicatorState extends State<_NfcPulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _NfcPulseIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !oldWidget.animate) {
      _controller.repeat();
    } else if (!widget.animate && oldWidget.animate) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.primary;
    return Column(
      key: ValueKey(widget.label),
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          height: 64,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final phase = widget.animate ? _controller.value : 0.0;
              final scale = 0.84 + phase * 0.22;
              final opacity = 0.34 * (1 - phase);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: tint.withValues(alpha: opacity),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tint.withValues(alpha: 0.12),
                    ),
                    child: Icon(
                      Icons.contactless_rounded,
                      color: tint,
                      size: 21,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Text(
          widget.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: tint,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _RegistrationHelpItem extends StatelessWidget {
  const _RegistrationHelpItem({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 5),
          Text(body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SelectionField extends StatelessWidget {
  final String label;
  final String value;
  final String placeholder;
  final VoidCallback? onTap;

  const _SelectionField({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = value.isEmpty
        ? (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary)
        : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimary);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            enabled: onTap != null,
            suffixIcon: const Icon(Icons.expand_more_rounded),
          ),
          child: Text(
            value.isEmpty ? placeholder : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: foreground, fontSize: 14),
          ),
        ),
      ),
    );
  }
}

class _ColorField extends StatelessWidget {
  final Color color;
  final String name;
  final VoidCallback? onTap;

  const _ColorField({
    required this.color,
    required this.name,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '颜色',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: InputDecorator(
          decoration: InputDecoration(
            enabled: onTap != null,
            labelText: '颜色',
            suffixIcon: const Icon(Icons.tune_rounded),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.outline),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name.trim().isNotEmpty
                      ? name.trim()
                      : color == Colors.white
                      ? '白色'
                      : '自定义颜色',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Verified CUID/FUID restoration metadata; AMS still needs device validation.
class _WriteResultBanner extends StatelessWidget {
  final RfidWriteSuccess result;

  const _WriteResultBanner({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tagType = result.tagType?.trim();
    final technology = result.technology?.trim();
    final verified = result.verified == true;
    final amsVerified = result.amsCompatibilityVerified;
    final templateRestored =
        result.amsCompatibility == 'template_restored_unverified';
    final color = amsVerified
        ? AppColors.success
        : (verified ? AppColors.info : AppColors.warning);
    final title = verified ? '完整模板与 UID 已回读校验' : 'CUID/FUID 模板校验未完成';
    final compatibility = amsVerified
        ? 'AMS 兼容性已由设备验证'
        : templateRestored
        ? 'AMS 兼容性待实机验证'
        : '请完成兼容模板校验后再登记耗材';
    final details = <String>[];
    if (tagType != null && tagType.isNotEmpty) details.add(tagType);
    if (technology != null && technology.isNotEmpty) details.add(technology);
    if (result.blocksWritten != null) {
      final verifiedBlocks = result.blocksVerified;
      details.add(
        verifiedBlocks == null
            ? '写入 ${result.blocksWritten} 个块'
            : '写入 ${result.blocksWritten} 个块，校验 $verifiedBlocks 个块',
      );
    } else if (result.bytesWritten != null) {
      details.add('写入 ${result.bytesWritten} 字节');
    }
    final secondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final surface = isDark ? AppColors.surfaceDark : AppColors.surface;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: isDark ? 0.16 : 0.08),
          surface,
        ),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            verified ? Icons.check_circle_outline_rounded : Icons.warning_amber,
            color: color,
            size: 21,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  compatibility,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    details.join(' · '),
                    style: TextStyle(
                      color: secondary,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MaterialPickerSheet extends StatefulWidget {
  final List<String> materials;
  final TextEditingController controller;

  const _MaterialPickerSheet({
    required this.materials,
    required this.controller,
  });

  @override
  State<_MaterialPickerSheet> createState() => _MaterialPickerSheetState();
}

class _MaterialPickerSheetState extends State<_MaterialPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final values = widget.materials
        .where((value) => query.isEmpty || value.toLowerCase().contains(query))
        .toList(growable: false);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottomInset),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选择耗材型号', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: widget.controller,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: '搜索桌面端型号库',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: values.isEmpty
                  ? const Center(child: Text('没有匹配的型号'))
                  : ListView.separated(
                      itemCount: values.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) => ListTile(
                        title: Text(values[index]),
                        onTap: () => Navigator.of(context).pop(values[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
