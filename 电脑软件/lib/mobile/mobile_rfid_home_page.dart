import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/personal_spool_policy.dart';
import '../core/services/filament_brand_identity_service.dart';
import '../core/services/material_identity_service.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/interaction_effects.dart';
import '../core/utils/brand_logo_utils.dart';
import '../core/utils/color_utils.dart';
import '../features/color_picker/color_picker_panel.dart';
import '../widgets/filament_spool_icon.dart';
import 'ams_tag_template.dart';
import 'ams_template_repository.dart';
import 'mobile_inventory_sync.dart';
import 'mobile_rfid_models.dart';
import 'mobile_rfid_tag_repository.dart';
import 'mobile_visual_theme.dart';
import 'rfid_native_bridge.dart';

/// Reader-first mobile NFC surface.
///
/// The home page deliberately contains one primary action. A successful read
/// opens a centered stock-receipt dialog; a structurally blank Classic 1K card
/// opens a separate centered write dialog. Complete Bambu-compatible bytes remain local and
/// immutable because changing user-facing fields would invalidate the signed
/// source template.
class MobileRfidHomePage extends StatefulWidget {
  const MobileRfidHomePage({
    super.key,
    required this.nfc,
    required this.sync,
    required this.loadMaterials,
    this.accountLabel,
    this.accountIdentity,
    this.ownerAccount,
    this.onAccountTap,
    this.tagRepository,
    this.amsTemplateRepository,
    this.isActive = true,
    this.pageTitle = '耗材标签',
  });

  final RfidNativeBridge nfc;
  final MobileInventorySync sync;
  final Future<List<String>> Function() loadMaterials;
  final String? accountLabel;
  final String? accountIdentity;
  final String? ownerAccount;
  final void Function(BuildContext context)? onAccountTap;
  final MobileRfidTagRepository? tagRepository;
  final AmsTemplateRepository? amsTemplateRepository;
  final bool isActive;
  final String pageTitle;

  @override
  State<MobileRfidHomePage> createState() => _MobileRfidHomePageState();
}

class _MobileRfidHomePageState extends State<MobileRfidHomePage>
    with WidgetsBindingObserver {
  bool _nfcStateKnown = false;
  bool _nfcAvailable = false;
  bool _nfcEnabled = false;
  bool _checkingNfc = false;
  bool _reading = false;
  bool _writing = false;
  bool _saving = false;
  bool _presentingCard = false;
  String? _progress;
  String? _feedback;
  bool _feedbackIsError = false;
  Future<bool>? _nfcCheck;
  int _operationGeneration = 0;
  int _accountGeneration = 0;
  List<String> _materials = const [
    'PLA',
    'PETG',
    'ABS',
    'ASA',
    'TPU',
    'PC',
    'PA',
    'PVA',
    'HIPS',
    'PP',
  ];

  AmsTemplateRepository get _templates =>
      widget.amsTemplateRepository ??
      const MethodChannelAmsTemplateRepository();

  bool get _busy =>
      _checkingNfc || _reading || _writing || _saving || _presentingCard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadMaterials());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) unawaited(_refreshNfcState());
    });
  }

  @override
  void didUpdateWidget(covariant MobileRfidHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive && (_reading || _writing)) {
      unawaited(_cancelOperation());
    }
    if (oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.ownerAccount != widget.ownerAccount) {
      _accountGeneration += 1;
      _operationGeneration += 1;
      if (_reading || _writing) unawaited(_cancelOperation());
      _feedback = null;
    }
    if (!oldWidget.isActive && widget.isActive) {
      unawaited(_refreshNfcState());
    }
    if (oldWidget.loadMaterials != widget.loadMaterials) {
      unawaited(_loadMaterials());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isActive) {
      unawaited(_refreshNfcState());
    } else if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        (_reading || _writing)) {
      unawaited(_cancelOperation());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _operationGeneration += 1;
    unawaited(widget.nfc.cancel());
    super.dispose();
  }

  Future<void> _loadMaterials() async {
    try {
      final source = await widget.loadMaterials();
      final normalized = <String>{..._materials};
      for (final value in source) {
        final family = MaterialIdentityService.normalize(value).family.trim();
        if (family.isNotEmpty) normalized.add(family);
      }
      final values = normalized.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (mounted) setState(() => _materials = values);
    } catch (_) {
      // The compact built-in type list keeps new-card registration available
      // when the desktop catalog or account snapshot is offline.
    }
  }

  Future<bool> _refreshNfcState() {
    final active = _nfcCheck;
    if (active != null) return active;
    if (mounted) setState(() => _checkingNfc = true);
    late final Future<bool> check;
    check = () async {
      try {
        final available = await widget.nfc.isAvailable();
        final enabled = available && await widget.nfc.isEnabled();
        if (mounted) {
          setState(() {
            _nfcStateKnown = true;
            _nfcAvailable = available;
            _nfcEnabled = enabled;
          });
        }
        return available && enabled;
      } catch (_) {
        if (mounted) {
          setState(() {
            _nfcStateKnown = true;
            _nfcAvailable = false;
            _nfcEnabled = false;
          });
        }
        return false;
      }
    }();
    _nfcCheck = check;
    return check.whenComplete(() {
      if (identical(_nfcCheck, check)) _nfcCheck = null;
      if (mounted) setState(() => _checkingNfc = false);
    });
  }

  Future<void> _readCard() async {
    if (_busy || !widget.isActive) return;
    final account = _accountGeneration;
    if (!await _refreshNfcState()) {
      if (mounted) {
        _showMessage(
          !_nfcAvailable ? '此设备不支持 NFC' : '请先在系统设置中开启 NFC',
          error: true,
        );
      }
      return;
    }
    if (!mounted || !widget.isActive || account != _accountGeneration) return;
    final nfc = widget.nfc;
    if (nfc is! AmsTemplateNfc) {
      _showMessage('当前设备没有 CUID/FUID 完整读取能力', error: true);
      return;
    }
    final operation = ++_operationGeneration;
    setState(() {
      _reading = true;
      _feedback = null;
      _progress = '请将 CUID/FUID 贴近手机 NFC 区域';
    });
    AmsTemplateReadResult result;
    try {
      result = await (nfc as AmsTemplateNfc).readAmsTemplate();
    } catch (_) {
      result = const AmsTemplateReadFailure(
        'READ_FAILED',
        '读取暂时中断，请重新贴近标签后再试。',
      );
    }
    if (!mounted ||
        operation != _operationGeneration ||
        account != _accountGeneration) {
      return;
    }
    setState(() {
      _reading = false;
      _progress = null;
      _presentingCard = true;
    });
    try {
      if (result is AmsTemplateReadSuccess) {
        try {
          await _templates.save(
            result.template,
            ownerAccount: widget.ownerAccount ?? '',
          );
        } catch (_) {
          if (mounted) {
            _showMessage('标签已读取，但兼容模板未能加密保存到本机', error: true);
          }
        }
        if (!mounted || !widget.isActive || account != _accountGeneration) {
          return;
        }
        final details = await _resolveDetails(result.template);
        if (!mounted || !widget.isActive || account != _accountGeneration) {
          return;
        }
        await _recordScan(details, result.template);
        if (!mounted || !widget.isActive || account != _accountGeneration) {
          return;
        }
        final receipt = await _showCenteredNfcDialog<_StockReceiptChoice>(
          context,
          builder: (_) => _ReadCardDialog(details: details),
        );
        if (receipt != null &&
            mounted &&
            widget.isActive &&
            account == _accountGeneration) {
          await _receiveStock(details, receipt);
        }
        return;
      }

      if (result is AmsTemplateReadFailure) {
        final code = result.code.trim().toLowerCase();
        if (code == 'blank_tag') {
          await _openNewCardWriter(account);
        } else if (code != 'operation_cancelled' && code != 'scan_cancelled') {
          _showMessage(result.message, error: true);
        }
      }
    } catch (_) {
      if (mounted && account == _accountGeneration) {
        _showMessage('资料暂时无法加载，请重新读取；库存尚未变更。', error: true);
      }
    } finally {
      if (mounted) setState(() => _presentingCard = false);
    }
  }

  Future<_ReadCardDetails> _resolveDetails(AmsTagTemplate template) async {
    final mappings = await _knownMappings(template.uid);
    RfidTagRecord? local = mappings.firstOrNull;
    final repository = widget.tagRepository;
    if (local == null && repository != null) {
      local = await repository.latestForTag(
        template.uid,
        ownerAccount: widget.ownerAccount ?? '',
        profile: 'ams',
      );
      if (local?.succeeded != true) local = null;
    }

    final rawBrand = local?.brand.trim().isNotEmpty == true
        ? local!.brand
        : '拓竹';
    final rawMaterial = local?.model.trim().isNotEmpty == true
        ? local!.model
        : template.material;
    final identity = MaterialIdentityService.normalize(rawMaterial);
    final material = identity.family.isNotEmpty
        ? identity.family
        : identity.displayName;
    final rawColor = local?.colorHex.trim() ?? '';
    final colorHex = RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(rawColor)
        ? rawColor.toUpperCase()
        : template.colorHex.toUpperCase();
    final draft = MobileConsumableDraft(
      brand: FilamentBrandIdentityService.normalize(rawBrand),
      model: material.isEmpty ? '未知类型' : material,
      color: ColorUtils.fromHex(colorHex),
      colorName: local?.colorName?.trim() ?? '',
    );
    final knownType = local?.tagType.trim().toUpperCase();
    return _ReadCardDetails(
      template: template,
      draft: draft,
      tagType: knownType == 'CUID' || knownType == 'FUID' ? knownType : null,
    );
  }

  Future<void> _recordScan(
    _ReadCardDetails details,
    AmsTagTemplate template,
  ) async {
    final repository = widget.tagRepository;
    if (repository == null) return;
    try {
      await repository.recordScan(
        tagUid: template.uid,
        tagType: details.tagType ?? '',
        technology: 'MIFARE_CLASSIC',
        profile: 'ams',
        ownerAccount: widget.ownerAccount,
        brand: details.draft.brand,
        model: details.draft.model,
        colorHex: details.draft.colorHex,
        colorName: details.draft.colorName,
        bytesRead: AmsTagTemplate.byteLength,
        verified: true,
        message: '完整 64 块已读取；AMS 兼容性仍以实机为准',
      );
    } catch (_) {
      // Inventory remains usable when the optional local audit table is busy.
    }
  }

  Future<void> _receiveStock(
    _ReadCardDetails details,
    _StockReceiptChoice choice,
  ) async {
    final sync = widget.sync;
    if (sync is! MobileInventoryStockSync) {
      _showMessage('当前库存服务版本不支持资料卡入库', error: true);
      return;
    }
    final account = _accountGeneration;
    setState(() {
      _saving = true;
      _progress = '正在保存耗材库存';
    });
    try {
      final result = await (sync as MobileInventoryStockSync).receiveFromCard(
        details.draft,
        operationUid: const Uuid().v4(),
        tagUid: details.template.uid,
        tagType: choice.tagType,
        quantity: choice.count,
        initialGrams: choice.initialGrams,
      );
      if (!mounted || account != _accountGeneration) return;
      final count = result.receipt.inventoryUids.length;
      _showMessage(
        '已加入 $count 卷，每卷固定 1000 g'
        '${choice.initialGrams < personalSpoolCapacityGrams ? '，当前余量 ${choice.initialGrams.toStringAsFixed(0)} g' : ''}'
        '${result.syncPending ? '；云端待同步' : ''}',
      );
    } catch (error) {
      if (mounted) _showMessage('入库失败：$error', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openNewCardWriter(int account) async {
    final selection = await _showCenteredNfcDialog<_NewCardChoice>(
      context,
      builder: (_) => _NewCardDialog(
        materials: _materials,
        repository: _templates,
        ownerAccount: widget.ownerAccount ?? '',
      ),
    );
    if (selection == null ||
        !mounted ||
        !widget.isActive ||
        account != _accountGeneration) {
      return;
    }
    await _writeNewCard(selection, account);
  }

  Future<void> _writeNewCard(_NewCardChoice selection, int account) async {
    final nfc = widget.nfc;
    final sync = widget.sync;
    final repository = widget.tagRepository;
    final owner = widget.ownerAccount;
    if (nfc is! AmsTemplateNfc) {
      _showMessage('当前设备没有 CUID/FUID 完整写入能力', error: true);
      return;
    }
    if (!await _mappingIsUnambiguous(selection) ||
        !mounted ||
        account != _accountGeneration) {
      return;
    }
    if (!await _refreshNfcState() ||
        !mounted ||
        account != _accountGeneration) {
      _showMessage('请开启 NFC 后重试', error: true);
      return;
    }
    final operation = ++_operationGeneration;
    setState(() {
      _writing = true;
      _progress = '请贴近目标 ${selection.targetKind.toUpperCase()} 并保持不动';
    });
    RfidWriteResult result;
    try {
      result = await (nfc as AmsTemplateNfc).restoreAmsTemplate(
        selection.template,
        targetKind: selection.targetKind,
        allowUidChange: true,
        onProgress: (state) {
          if (!mounted || operation != _operationGeneration) return;
          setState(() {
            _progress = switch (state) {
              'awaiting_reselect' => '请将标签移开，再贴回手机完成新 UID 校验',
              'verifying' => '正在回读全部 64 块，请保持标签不动',
              _ => '正在写入 AMS 兼容模板，请保持标签不动',
            };
          });
        },
      );
    } catch (_) {
      result = const RfidWriteFailure(
        'WRITE_FAILED',
        '写入中断，标签可能已部分写入。请保留所选源模板并重新检查标签。',
      );
    }
    if (!mounted ||
        operation != _operationGeneration ||
        account != _accountGeneration) {
      return;
    }
    if (result is RfidWriteFailure) {
      setState(() {
        _writing = false;
        _progress = null;
      });
      _showMessage(result.message, error: true);
      return;
    }
    final written = result as RfidWriteSuccess;
    final valid =
        written.verified == true &&
        written.blocksVerified == 64 &&
        written.tagId?.toUpperCase() == selection.template.uid.toUpperCase() &&
        written.amsCompatibility == 'template_restored_unverified';
    if (!valid) {
      setState(() {
        _writing = false;
        _progress = null;
      });
      _showMessage('全卡或新 UID 尚未校验通过，未加入库存', error: true);
      return;
    }

    setState(() {
      _saving = true;
      _progress = '标签已校验，正在登记 1 卷耗材';
    });
    try {
      final saved = await sync.save(
        selection.draft,
        tagId: written.tagId,
        tagType: selection.targetKind.toUpperCase(),
        initialGrams: personalSpoolCapacityGrams,
      );
      if (!mounted || account != _accountGeneration) return;
      await _recordWriteAndBinding(
        written,
        selection,
        saved,
        repository: repository,
        owner: owner,
      );
      if (!mounted || account != _accountGeneration) return;
      final message = saved.requiresReplacement
          ? '标签已写入，请到库存详情确认换卷；原余量已保留'
          : '写入完成，耗材已保存；已有卷的余量保持不变';
      _showMessage('$message${saved.syncPending ? '；云端待同步' : ''}。');
    } catch (error) {
      if (mounted) {
        _showMessage('标签已写入，但库存保存失败：$error', error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _writing = false;
          _saving = false;
          _progress = null;
        });
      }
    }
  }

  Future<bool> _mappingIsUnambiguous(_NewCardChoice selection) async {
    try {
      final mappings = await _knownMappings(selection.template.uid);
      for (final previous in mappings) {
        final sameBrand = FilamentBrandIdentityService.sameBrand(
          previous.brand,
          selection.draft.brand,
        );
        final sameMaterial = MaterialIdentityService.sameFamily(
          previous.model,
          selection.draft.model,
        );
        final sameColor =
            previous.colorHex.trim().toUpperCase() ==
            selection.draft.colorHex.toUpperCase();
        if (sameBrand && sameMaterial && sameColor) continue;
        _showMessage(
          '这个源模板的 UID 已绑定为 ${previous.brand} · ${previous.model} · ${previous.colorHex}。'
          '同一模板复制卡无法区分，请选择匹配资料或换一个源模板。',
          error: true,
        );
        return false;
      }
      return true;
    } catch (_) {
      _showMessage('无法核对源模板现有映射，已停止写卡', error: true);
      return false;
    }
  }

  Future<List<RfidTagRecord>> _knownMappings(String uid) async {
    final repository = widget.tagRepository;
    if (repository == null) return const [];
    final owner = widget.ownerAccount ?? '';
    final groups = await Future.wait([
      repository.listInventoryTagBindings(ownerAccount: owner, limit: 500),
      repository.list(
        ownerAccount: owner,
        tagUid: uid,
        profile: 'ams',
        operation: 'write',
        limit: 100,
      ),
    ]);
    bool matches(RfidTagRecord record) =>
        record.succeeded &&
        record.isConsumableTagRecord &&
        record.tagUid.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase() ==
            uid.toUpperCase() &&
        record.brand.trim().isNotEmpty &&
        record.model.trim().isNotEmpty &&
        RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(record.colorHex.trim());
    // Synced inventory is the current source of truth; scan history is only
    // a fallback and must not hide later changes made on the desktop.
    final bindings = groups[0].where(matches).toList();
    if (bindings.isNotEmpty) return bindings;
    final latestWrite = groups[1].where(matches).firstOrNull;
    return [if (latestWrite != null) latestWrite];
  }

  Future<void> _recordWriteAndBinding(
    RfidWriteSuccess result,
    _NewCardChoice selection,
    MobileInventorySaveResult saved, {
    required MobileRfidTagRepository? repository,
    required String? owner,
  }) async {
    if (repository == null || result.tagId?.trim().isEmpty != false) return;
    final tagUid = result.tagId!;
    try {
      await repository.recordWrite(
        tagUid: tagUid,
        tagType: selection.targetKind.toUpperCase(),
        technology: result.technology ?? 'MIFARE_CLASSIC',
        ownerAccount: owner,
        inventoryUid: saved.inventoryUid,
        brand: selection.draft.brand,
        model: selection.draft.model,
        colorHex: selection.draft.colorHex,
        colorName: selection.draft.colorName,
        bytesWritten: result.bytesWritten,
        blocksWritten: result.blocksWritten,
        blocksVerified: result.blocksVerified,
        verified: true,
        message: '完整模板写入并回读；AMS 兼容性待实机验证',
      );
      if (!saved.requiresReplacement) {
        await repository.recordBinding(
          tagUid: tagUid,
          inventoryUid: saved.inventoryUid,
          ownerAccount: owner,
          tagType: selection.targetKind.toUpperCase(),
          technology: result.technology ?? 'MIFARE_CLASSIC',
          brand: selection.draft.brand,
          model: selection.draft.model,
          colorHex: selection.draft.colorHex,
          colorName: selection.draft.colorName,
          cycle: saved.rfidTagCycle,
          message: '手机新卡写入',
        );
      }
    } catch (_) {
      // Successful physical write and inventory save are authoritative; audit
      // reconciliation can retry independently.
    }
  }

  Future<void> _cancelOperation() async {
    _operationGeneration += 1;
    try {
      await widget.nfc.cancel();
    } finally {
      if (mounted) {
        setState(() {
          _reading = false;
          _writing = false;
          _progress = null;
        });
      }
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _feedback = message;
      _feedbackIsError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = !_nfcStateKnown
        ? '正在检测 NFC'
        : !_nfcAvailable
        ? '此设备不支持 NFC'
        : !_nfcEnabled
        ? 'NFC 未开启'
        : 'NFC 已就绪';
    final statusColor = !_nfcStateKnown
        ? AppColors.info
        : (!_nfcAvailable || !_nfcEnabled)
        ? AppColors.warning
        : AppColors.success;
    return MobileScaffold(
      appBar: AppBar(
        flexibleSpace: const MobileGlassBar(),
        title: Text(widget.pageTitle),
        actions: [
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
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 36).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('mobile-reader-nfc-status'),
                      onPressed: _busy ? null : _refreshNfcState,
                      style: TextButton.styleFrom(
                        foregroundColor: statusColor,
                        backgroundColor: statusColor.withValues(alpha: 0.08),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        shape: const StadiumBorder(),
                      ),
                      icon: _checkingNfc
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: statusColor,
                              ),
                            )
                          : Icon(
                              Icons.nfc_rounded,
                              size: 18,
                              color: statusColor,
                            ),
                      label: Text(status, style: TextStyle(color: statusColor)),
                    ),
                  ),
                  SizedBox(height: constraints.maxHeight > 600 ? 48 : 24),
                  _ReaderPulse(
                    animate:
                        (_reading || _writing) && AppMotion.enabled(context),
                    active: _reading || _writing,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    _reading
                        ? '正在认识这一卷'
                        : _writing
                        ? '正在为耗材写卡'
                        : '贴近，读懂这一卷',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _progress ?? '轻触读取，再将标签贴近手机背面。\n已有耗材直接入库，新卡按提示填写。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.65,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('mobile-reader-primary'),
                        onPressed: _busy || !widget.isActive ? null : _readCard,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 60),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        icon: _reading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.contactless_rounded, size: 26),
                        label: Text(
                          _reading
                              ? '正在读取…'
                              : _writing
                              ? '正在写入…'
                              : _saving
                              ? '正在保存…'
                              : '读取 CUID / FUID',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_reading || _writing) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _cancelOperation,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('取消'),
                    ),
                  ],
                  if (_feedback != null) ...[
                    const SizedBox(height: 20),
                    _ReaderNotice(message: _feedback!, error: _feedbackIsError),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'CUID / FUID · 耗材标签',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      letterSpacing: 1.0,
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
}

Future<T?> _showCenteredNfcDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showMobileGlassDialog<T>(context: context, builder: builder);
}

class _ReadCardDetails {
  const _ReadCardDetails({
    required this.template,
    required this.draft,
    required this.tagType,
  });
  final AmsTagTemplate template;
  final MobileConsumableDraft draft;
  final String? tagType;
}

class _StockReceiptChoice {
  const _StockReceiptChoice({
    required this.count,
    required this.initialGrams,
    required this.tagType,
  });
  final int count;
  final double initialGrams;
  final String tagType;
}

enum _StockMode { rolls, grams }

class _ReadCardDialog extends StatefulWidget {
  const _ReadCardDialog({required this.details});
  final _ReadCardDetails details;

  @override
  State<_ReadCardDialog> createState() => _ReadCardDialogState();
}

class _ReadCardDialogState extends State<_ReadCardDialog> {
  _StockMode _mode = _StockMode.rolls;
  int _count = 1;
  final _quantity = TextEditingController(text: '1');
  String _tagType = 'CUID';
  final _grams = TextEditingController(text: '1000');
  String? _error;

  @override
  void initState() {
    super.initState();
    _tagType = widget.details.tagType ?? 'CUID';
  }

  @override
  void dispose() {
    _grams.dispose();
    _quantity.dispose();
    super.dispose();
  }

  void _submit() {
    if (_mode == _StockMode.rolls) {
      final count = int.tryParse(_quantity.text.trim());
      if (count == null || count < 1 || count > 100) {
        setState(() => _error = '请输入 1 到 100 卷');
        return;
      }
      _count = count;
    }
    final grams = _mode == _StockMode.rolls
        ? personalSpoolCapacityGrams
        : double.tryParse(_grams.text.trim());
    if (grams == null || !canReusePersonalSpool(grams)) {
      setState(() => _error = '余量必须大于 30 g 且不超过 1000 g');
      return;
    }
    Navigator.of(context).pop(
      _StockReceiptChoice(
        count: _mode == _StockMode.rolls ? _count : 1,
        initialGrams: grams,
        tagType: _tagType,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.details.draft;
    final logo = BrandLogoUtils.resolveAsset(draft.brand);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _CardDialogHeader(
              title: '读取到耗材资料',
              subtitle: '核对这一卷，然后选择入库数量。',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  colors: [
                    draft.color.withValues(alpha: 0.14),
                    Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: 0.7),
                  ],
                ),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  FilamentSpoolIcon(
                    color: draft.color,
                    size: 42,
                    dimensional: true,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (logo != null) ...[
                          SizedBox(
                            width: 56,
                            height: 24,
                            child: Image.asset(
                              logo,
                              alignment: Alignment.centerLeft,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          draft.brand,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${draft.model} · ${draft.colorName.isEmpty ? draft.colorHex : draft.colorName}',
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: draft.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_StockMode>(
              key: const ValueKey('mobile-read-stock-mode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _StockMode.rolls, label: Text('按卷数')),
                ButtonSegment(value: _StockMode.grams, label: Text('按克数')),
              ],
              selected: {_mode},
              onSelectionChanged: (value) => setState(() {
                _mode = value.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 14),
            if (_mode == _StockMode.rolls)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('新增卷数', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '减少一卷',
                        onPressed: _count > 1
                            ? () => setState(() {
                                _count--;
                                _quantity.text = '$_count';
                                _error = null;
                              })
                            : null,
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('mobile-read-roll-count'),
                          controller: _quantity,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(
                            suffixText: '卷',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onChanged: (value) => setState(() {
                            _count = int.tryParse(value) ?? 0;
                            _error = null;
                          }),
                        ),
                      ),
                      IconButton(
                        tooltip: '增加一卷',
                        onPressed: _count < 100
                            ? () => setState(() {
                                _count = (_count + 1).clamp(1, 100);
                                _quantity.text = '$_count';
                                _error = null;
                              })
                            : null,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '每卷固定 1000 g',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )
            else
              TextField(
                key: const ValueKey('mobile-read-grams'),
                controller: _grams,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: '当前余量',
                  suffixText: 'g',
                  helperText: '单卷仍固定为 1000 g；这里只登记当前剩余克数。',
                  helperMaxLines: 2,
                ),
              ),
            if (widget.details.tagType == null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _tagType,
                decoration: const InputDecoration(labelText: '确认卡型'),
                items: const [
                  DropdownMenuItem(value: 'CUID', child: Text('CUID')),
                  DropdownMenuItem(value: 'FUID', child: Text('FUID')),
                ],
                onChanged: (value) =>
                    setState(() => _tagType = value ?? 'CUID'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey('mobile-read-confirm-stock'),
              onPressed: _submit,
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(
                _mode == _StockMode.rolls ? '确认新增 $_count 卷' : '确认余量入库',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewCardChoice {
  const _NewCardChoice({
    required this.draft,
    required this.template,
    required this.targetKind,
  });
  final MobileConsumableDraft draft;
  final AmsTagTemplate template;
  final String targetKind;
}

class _NewCardDialog extends StatefulWidget {
  const _NewCardDialog({
    required this.materials,
    required this.repository,
    required this.ownerAccount,
  });
  final List<String> materials;
  final AmsTemplateRepository repository;
  final String ownerAccount;

  @override
  State<_NewCardDialog> createState() => _NewCardDialogState();
}

class _NewCardDialogState extends State<_NewCardDialog> {
  final _brand = TextEditingController();
  Color _color = Colors.white;
  String _colorName = '';
  String? _material;
  String _targetKind = 'cuid';
  List<AmsTagTemplate> _templates = const [];
  AmsTagTemplate? _template;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTemplates());
  }

  @override
  void dispose() {
    _brand.dispose();
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final values = await widget.repository.list(
        ownerAccount: widget.ownerAccount,
      );
      if (!mounted) return;
      setState(() {
        _templates = values;
        _template = values.firstOrNull;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '本机兼容模板库暂不可用';
        });
      }
    }
  }

  Future<void> _pickColor() async {
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

  void _submit() {
    final brand = FilamentBrandIdentityService.normalize(_brand.text);
    final material = _material?.trim() ?? '';
    if (brand.isEmpty) {
      setState(() => _error = '请输入耗材品牌');
      return;
    }
    if (material.isEmpty) {
      setState(() => _error = '请选择耗材类型');
      return;
    }
    if (_template == null) {
      setState(() => _error = '请先用首页读取一张可被 AMS 识别的源标签');
      return;
    }
    Navigator.of(context).pop(
      _NewCardChoice(
        draft: MobileConsumableDraft(
          brand: brand,
          model: MaterialIdentityService.normalize(material).family,
          color: _color,
          colorName: _colorName,
        ),
        template: _template!,
        targetKind: _targetKind,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canonicalBrand = FilamentBrandIdentityService.normalize(_brand.text);
    final logo = BrandLogoUtils.resolveAsset(canonicalBrand);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _CardDialogHeader(
              title: '写入新卡',
              subtitle: '发现一张空白标签，填写它对应的耗材。',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('mobile-new-card-brand'),
              controller: _brand,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: '耗材品牌',
                hintText: '例如：拓竹、Bambu、eSUN',
                prefixIcon: logo == null
                    ? const Icon(Icons.sell_outlined)
                    : Padding(
                        padding: const EdgeInsets.all(11),
                        child: Image.asset(logo, width: 24, height: 24),
                      ),
              ),
            ),
            if (canonicalBrand.isNotEmpty &&
                canonicalBrand != _brand.text.trim()) ...[
              const SizedBox(height: 6),
              Text(
                '已识别为 $canonicalBrand，与桌面品牌一致',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: mobileAccentTextColor(Theme.of(context)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('mobile-new-card-material'),
              initialValue: _material,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '耗材类型',
                helperText: '只显示 PLA、PETG、ABS 等类型，不带品牌前缀。',
                helperMaxLines: 3,
              ),
              items: [
                for (final material in widget.materials)
                  DropdownMenuItem(value: material, child: Text(material)),
              ],
              onChanged: (value) => setState(() {
                _material = value;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            ListTile(
              key: const ValueKey('mobile-new-card-color'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Theme.of(context).dividerColor),
              ),
              leading: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: _color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
              ),
              title: const Text('颜色'),
              subtitle: Text(
                _colorName.isEmpty ? ColorUtils.toHex(_color) : _colorName,
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickColor,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else
              ExpansionTile(
                key: const ValueKey('mobile-new-card-compatibility'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 12),
                initiallyExpanded: _templates.isEmpty,
                title: const Text('标签兼容设置'),
                subtitle: Text(
                  _loading
                      ? '正在加载…'
                      : _template == null
                      ? '需要先读取一个源模板'
                      : '${_targetKind.toUpperCase()} · ${_template!.material}',
                ),
                children: [
                  DropdownButtonFormField<AmsTagTemplate>(
                    key: const ValueKey('mobile-new-card-template'),
                    initialValue: _template,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'AMS 兼容源模板'),
                    items: [
                      for (final template in _templates)
                        DropdownMenuItem(
                          value: template,
                          child: Text(
                            '${template.material} · ${template.colorHex} · ${template.uid.substring(4)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loading
                        ? null
                        : (value) => setState(() {
                            _template = value;
                            _error = null;
                          }),
                  ),
                  if (!_loading && _templates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('还没有源模板：先关闭此弹窗，用首页读取一张拓竹原厂或已验证兼容标签。'),
                    ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    key: const ValueKey('mobile-new-card-kind'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'cuid', label: Text('CUID / Gen2')),
                      ButtonSegment(value: 'fuid', label: Text('FUID')),
                    ],
                    selected: {_targetKind},
                    onSelectionChanged: (value) => setState(() {
                      _targetKind = value.single;
                      _error = null;
                    }),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _targetKind == 'fuid'
                        ? 'FUID 的 UID 通常只能改写一次。'
                        : '仅支持可通过标准 Block 0 写入的兼容 CUID/Gen2 卡。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            Text(
              'AMS 使用源模板的耗材参数；上面填写的资料用于 Sohun 库存。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '同一源模板复制出的卡共用同一 UID，只能对应同一种 Sohun 耗材资料，不能同时独立追踪多种卷。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey('mobile-new-card-write'),
              onPressed: _loading ? null : _submit,
              icon: const Icon(Icons.nfc_rounded),
              label: const Text('开始写入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReaderPulse extends StatefulWidget {
  const _ReaderPulse({required this.animate, required this.active});
  final bool animate;
  final bool active;

  @override
  State<_ReaderPulse> createState() => _ReaderPulseState();
}

class _ReaderPulseState extends State<_ReaderPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ReaderPulse oldWidget) {
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
    final color = Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: SizedBox(
        width: 208,
        height: 208,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) {
            final value = widget.animate ? _controller.value : 0.0;
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: 0.15),
                        color.withValues(alpha: 0.025),
                      ],
                    ),
                  ),
                ),
                Transform.scale(
                  scale: 0.87 + value * 0.13,
                  child: Container(
                    width: 198,
                    height: 198,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withValues(
                          alpha: widget.active ? 0.26 * (1 - value) : 0.12,
                        ),
                        width: 1,
                      ),
                    ),
                  ),
                ),
                child!,
                Positioned(
                  right: 25,
                  bottom: 26,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(15),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.22),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.nfc_rounded,
                      color: Theme.of(context).colorScheme.onPrimary,
                      size: 24,
                    ),
                  ),
                ),
              ],
            );
          },
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.8),
              border: Border.all(color: color.withValues(alpha: 0.14)),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.08),
                  blurRadius: 26,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Center(
              child: Transform.rotate(
                angle: -0.12,
                child: FilamentSpoolIcon(
                  color: color,
                  size: 60,
                  dimensional: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderNotice extends StatelessWidget {
  const _ReaderNotice({required this.message, required this.error});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Semantics(
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.15)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error
                  ? Icons.info_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: color,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardDialogHeader extends StatelessWidget {
  const _CardDialogHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    ],
  );
}
