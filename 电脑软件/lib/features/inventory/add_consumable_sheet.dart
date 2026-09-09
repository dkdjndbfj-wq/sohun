import 'package:drift/drift.dart' show Value;
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/services/personal_inventory_sync_service.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/models/filament_cost_config.dart';
import '../../data/models/personal_inventory_sync.dart';
import '../../data/external/slicer/material_catalog_service.dart';
import '../../data/seed/printer_seed.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/app_auth_provider.dart';
import '../../providers/material_catalog_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_select.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/material_picker.dart';
import '../color_picker/color_picker_panel.dart';

/// 新增/编辑耗材表单。苹果风格居中弹窗：
/// 顶部图标徽章 + 标题，表单字段聚焦光环，底部 AppButton 保存。
/// 通过 [showGeneralDialog] 弹出，含 scale + fade 入场动效。
class AddConsumableSheet extends ConsumerStatefulWidget {
  /// 编辑时传入已有耗材；新增时为 null。
  final Consumable? edit;
  final String? initialManufacturer;
  final String? initialMaterial;
  final String? initialColorHex;
  final String? initialColorName;
  final String? farmWorkspaceId;

  const AddConsumableSheet({
    super.key,
    this.edit,
    this.initialManufacturer,
    this.initialMaterial,
    this.initialColorHex,
    this.initialColorName,
    this.farmWorkspaceId,
  });

  /// 弹出表单。edit 为 null 时是新增，否则编辑现有耗材。
  /// 使用 showGeneralDialog 居中弹窗，maxWidth 480，maxHeight 85% 屏高，
  /// 入场 scale 0.92→1 + fade（220ms easeOutBack）。
  static Future<int?> show(
    BuildContext context, {
    Consumable? edit,
    String? initialManufacturer,
    String? initialMaterial,
    String? initialColorHex,
    String? initialColorName,
    String? farmWorkspaceId,
  }) {
    return showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: const Color(0x4D000000), // 半透明遮罩
      transitionDuration: AppCurves.durationModal,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        // scale 0.92→1，使用 curveModal（easeOutBack 轻微回弹）
        final scale = Tween<double>(begin: 0.92, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: AppCurves.curveModal),
        );
        // 淡入
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        // 键盘出现时整体上移，避免遮挡输入与保存按钮
        final mq = MediaQuery.of(context);
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 480,
                maxHeight: mq.size.height * 0.85,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: GlassCard(
                  level: GlassLevel.l3,
                  borderRadius: BorderRadius.circular(AppColors.radiusXl),
                  padding: const EdgeInsets.all(22),
                  child: AddConsumableSheet(
                    edit: edit,
                    initialManufacturer: initialManufacturer,
                    initialMaterial: initialMaterial,
                    initialColorHex: initialColorHex,
                    initialColorName: initialColorName,
                    farmWorkspaceId: farmWorkspaceId,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  ConsumerState<AddConsumableSheet> createState() => _AddConsumableSheetState();
}

class _AddConsumableSheetState extends ConsumerState<AddConsumableSheet> {
  final _entryOperationUid = const Uuid().v4();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _manufacturerController;
  late final TextEditingController _noteController;
  late final TextEditingController _totalDisplayController;
  late final TextEditingController _priceController;
  // v12：耗材物理参数（密度/推荐温度），吸湿性用下拉
  late final TextEditingController _densityController;
  late final TextEditingController _nozzleTempController;
  final _remainingController = TextEditingController();
  bool _enterRemaining = false;
  String? _remainingError;
  int get _maxRolls => widget.farmWorkspaceId == null ? 100 : 999;

  late String _material;
  late Color _color;
  late String _colorName;
  // 卷数：加减号 + 输入框双通道
  late int _rolls;
  // 吸湿性档位：null 表示未设置（按材质名推断）
  String? _hygroscopicity;

  // Autocomplete 内部管理 manufacturer 的 controller，这里保留引用用于读取/校验
  TextEditingController? _autocompleteController;

  /// 保存进行中标志：防止连点导致重复插入
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _manufacturerController = TextEditingController(
      text: e?.manufacturer ?? widget.initialManufacturer ?? '',
    );
    // 编辑时用 remainingGrams（与卡片显示一致），新增时默认 1 卷
    _rolls = e != null ? (e.remainingGrams / 1000).round() : 1;
    _totalDisplayController = TextEditingController(text: '$_rolls');
    _noteController = TextEditingController(text: e?.note ?? '');
    _material = e?.materialType ?? widget.initialMaterial ?? 'PLA';
    _color = ColorUtils.fromHex(
      e?.colorHex ?? widget.initialColorHex ?? '#FFFFFF',
    );
    _colorName = e?.colorName ?? widget.initialColorName ?? '';
    // 单价（元/卷）：编辑时尝试从耗材成本配置读取已有单价，没有就空
    _priceController = TextEditingController(text: '');
    // v12 参数默认空，编辑时从 DB 加载
    _densityController = TextEditingController(text: '');
    _nozzleTempController = TextEditingController(text: '');
    _hygroscopicity = null;
    if (e != null) {
      _loadExistingPrice(e);
      _loadExistingParams(e);
    }
  }

  /// 编辑时从 DB 加载耗材物理参数（v12）。
  Future<void> _loadExistingParams(Consumable e) async {
    try {
      final dao = ref.read(consumableDaoProvider);
      final params = await dao.getParams(e.id);
      if (!mounted) return;
      setState(() {
        if (params.density != null) {
          _densityController.text = params.density!.toStringAsFixed(2);
        }
        if (params.recommendedNozzleTemp != null) {
          _nozzleTempController.text = params.recommendedNozzleTemp!
              .toStringAsFixed(0);
        }
        _hygroscopicity = params.hygroscopicity;
      });
    } catch (_) {}
  }

  /// 保存耗材物理参数到 DB（v12，raw SQL）。
  ///
  /// 解析输入框文本：空字符串 → 清除字段（clearXxx=true），
  /// 有效数字 → 写入，无效数字 → 忽略该字段。
  Future<void> _saveParams(ConsumableDao dao, int id) async {
    try {
      final densityText = _densityController.text.trim();
      final tempText = _nozzleTempController.text.trim();
      final density = double.tryParse(densityText);
      final temp = double.tryParse(tempText);

      // 判断清除：文本为空时清除字段；有文本但解析失败时不处理（保留原值）
      await dao.setParams(
        id,
        density: density,
        recommendedNozzleTemp: temp,
        hygroscopicity: _hygroscopicity,
        clearDensity: densityText.isEmpty,
        clearTemp: tempText.isEmpty,
        clearHygro: _hygroscopicity == null,
      );
    } catch (_) {}
  }

  /// v12：按材质名返回默认密度（g/cm³），未知材质返回 null。
  ///
  /// 数据来源：常见耗材公开参数，用于选材质时自动预填（用户可改）。
  static double? _defaultDensityFor(String material) {
    final m = material.toLowerCase();
    if (m.contains('pla')) return 1.24;
    if (m.contains('petg')) return 1.27;
    if (m.contains('abs') || m.contains('asa')) return 1.04;
    if (m.contains('tpu') || m.contains('tpe')) return 1.21;
    if (m.contains('nylon') || m.contains('pa')) return 1.14;
    if (m.contains('pc')) return 1.20;
    if (m.contains('pva') || m.contains('hips')) return 1.05;
    if (m.contains('pp')) return 0.90;
    return null;
  }

  /// 编辑时从耗材成本配置表读取已有单价（按 vendor+material+color 匹配）
  Future<void> _loadExistingPrice(Consumable e) async {
    try {
      final dao = ref.read(filamentCostConfigDaoProvider);
      final config = await dao.matchCost(
        vendor: e.manufacturer,
        materialType: e.materialType,
        colorHex: e.colorHex,
      );
      if (config != null && mounted) {
        // 每公斤单价 × 1kg = 每卷单价
        setState(() {
          _priceController.text = config.costPerKg.toStringAsFixed(2);
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _manufacturerController.dispose();
    _totalDisplayController.dispose();
    _noteController.dispose();
    _priceController.dispose();
    _densityController.dispose();
    _nozzleTempController.dispose();
    _remainingController.dispose();
    super.dispose();
  }

  // 加减卷数
  void _changeRolls(int delta) {
    setState(() {
      _rolls = (_rolls + delta).clamp(1, _maxRolls);
      _totalDisplayController.text = '$_rolls';
    });
  }

  // 输入框手动输入卷数
  void _onRollsInput(String v) {
    final n = int.tryParse(v.trim());
    if (n != null && n > 0) {
      setState(() {
        _rolls = n;
      });
    }
  }

  // 弹出颜色选择面板（嵌套 BottomSheet）
  Future<void> _pickColor() async {
    final result = await ColorPickerPanel.show(
      context,
      initial: _color,
      initialName: _colorName,
    );
    if (result != null) {
      setState(() {
        _color = result.color;
        _colorName = result.name;
      });
    }
  }

  // 校验并保存
  Future<void> _save() async {
    // 防重复提交：慢速磁盘下连点两次会插入两条重复耗材
    if (_saving) return;

    // 先收起键盘触发 TextFormField 校验
    FocusScope.of(context).unfocus();
    // 手动校验厂商（Autocomplete 的 controller 不在 Form 体系内）
    final manufacturer =
        (_autocompleteController?.text ?? _manufacturerController.text).trim();
    if (manufacturer.isEmpty) {
      showSnack(context, '请输入厂商', error: true);
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (widget.edit == null &&
        widget.farmWorkspaceId == null &&
        _enterRemaining) {
      final remaining = double.tryParse(_remainingController.text.trim());
      if (remaining == null ||
          !remaining.isFinite ||
          remaining <= 0 ||
          remaining > 1000) {
        setState(() => _remainingError = '请输入大于 0 且不超过 1000 g 的剩余克数');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      await _persist(manufacturer);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        // 保留用户已填内容，不关闭面板，便于修正后重试
        showSnack(context, '保存失败：${friendlyError(e)}', error: true);
      }
      return;
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _persist(String manufacturer) async {
    // 型号即材质：删除型号输入栏后，model 字段直接保存材质值
    final model = _material;
    // 卷数（加减号或输入），内部换算成克数存储（1 卷 = 1000g）
    final total = _rolls * 1000.0;
    final note = _noteController.text.trim();
    final colorHex = ColorUtils.toHex(_color);
    final colorName = _colorName.trim();

    final dao = ref.read(consumableDaoProvider);
    late final int savedId;

    if (widget.edit == null && widget.farmWorkspaceId == null) {
      final now = DateTime.now();
      // A 1 kg roll is a distinct inventory object. A remnant records only
      // its actual weight at intake, without inventing earlier consumption.
      final session = ref.read(appAuthProvider).session;
      final owner = session != null && session.authRealm == 'personal'
          ? PersonalInventorySyncService.ownerAccountFor(session)
          : null;
      final receipt = await dao.addPersonalStockManual(
        operationUid: _entryOperationUid,
        quantity: _enterRemaining ? 1 : _rolls,
        template: PersonalInventoryRecord(
          uid: 'desktop-manual-entry',
          manufacturer: manufacturer,
          model: model,
          materialType: _material,
          colorHex: colorHex,
          colorName: colorName.isEmpty ? null : colorName,
          totalGrams: _enterRemaining
              ? double.parse(_remainingController.text.trim())
              : 1000,
          remainingGrams: _enterRemaining
              ? double.parse(_remainingController.text.trim())
              : 1000,
          note: note.isEmpty ? null : note,
          createdAt: now,
          updatedAt: now,
          density: double.tryParse(_densityController.text.trim()),
          recommendedNozzleTemp: double.tryParse(
            _nozzleTempController.text.trim(),
          ),
          hygroscopicity: _hygroscopicity,
        ),
        ownerAccount: owner,
      );
      if (receipt.consumableIds.isEmpty) throw StateError('该入库批次已处理，请返回库存核对');
      savedId = receipt.consumableIds.first;
      for (final id in receipt.consumableIds) {
        await _saveParams(dao, id);
      }
    } else if (widget.edit == null) {
      // 新增：totalGrams 和 remainingGrams 都用卷数 * 1000
      // 耗材全局共享，不按账号隔离
      final entry = ConsumablesCompanion.insert(
        manufacturer: manufacturer,
        model: model,
        uid: Value(const Uuid().v4()),
        materialType: Value(_material),
        colorHex: Value(colorHex),
        colorName: Value(colorName.isEmpty ? null : colorName),
        totalGrams: Value(total),
        remainingGrams: Value(total),
        note: Value(note.isEmpty ? null : note),
      );
      final newId = await dao.addFarmConsumable(
        entry,
        workspaceId: widget.farmWorkspaceId!,
      );
      savedId = newId;
      // v12：写入耗材物理参数（用户手填或 RFID 预填）
      await _saveParams(dao, newId);
    } else {
      savedId = widget.edit!.id;
      if (widget.farmWorkspaceId == null) {
        final scope = ref.read(personalInventoryAccountScopeProvider);
        final allowed =
            !scope.enforce ||
            await dao.ensurePersonalConsumableAccess(
              savedId,
              ownerAccount: scope.ownerAccount,
              claimAnonymous: true,
            );
        if (!allowed) {
          throw StateError('账号已切换，请关闭对话框后重试');
        }
      }
      // 编辑：只更新元数据，不覆盖 remainingGrams/totalGrams
      // 库存调整通过卡片加减号或通道"已用完"操作，避免 round() 损失精度
      await dao.updateConsumable(
        ConsumablesCompanion(
          id: Value(widget.edit!.id),
          manufacturer: Value(manufacturer),
          model: Value(model),
          materialType: Value(_material),
          colorHex: Value(colorHex),
          colorName: Value(colorName.isEmpty ? null : colorName),
          note: Value(note.isEmpty ? null : note),
          updatedAt: Value(DateTime.now()),
        ),
      );
      // v12：更新耗材物理参数
      await _saveParams(dao, widget.edit!.id);
    }

    // 同步写入耗材成本配置（按 vendor + material + color 匹配）
    // 用户在耗材添加表单里填了单价（元/卷），就同步到成本配置表，
    // 这样切片时能自动按克数估算成本。
    final priceText = _priceController.text.trim();
    if (priceText.isNotEmpty) {
      final pricePerRoll = double.tryParse(priceText);
      if (pricePerRoll != null && pricePerRoll > 0) {
        // 每公斤单价 = 每卷单价（1 卷 = 1kg = 1000g）
        final costPerKg = pricePerRoll;
        try {
          final costDao = ref.read(filamentCostConfigDaoProvider);
          // 查找是否已有同 vendor+material+color 的配置
          final existing = await costDao.matchCost(
            vendor: manufacturer,
            materialType: _material,
            colorHex: colorHex,
          );
          if (existing != null) {
            // 已有配置：更新单价
            await costDao.updateConfig(
              FilamentCostConfig(
                id: existing.id,
                vendor: manufacturer,
                materialType: _material,
                colorHex: colorHex,
                costPerKg: costPerKg,
                note: note.isEmpty ? existing.note : note,
                createdAt: existing.createdAt,
                updatedAt: DateTime.now(),
              ),
            );
          } else {
            // 没有配置：新建
            await costDao.create(
              FilamentCostConfig(
                vendor: manufacturer,
                materialType: _material,
                colorHex: colorHex,
                costPerKg: costPerKg,
                note: note.isEmpty ? null : note,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            );
          }
        } catch (_) {
          // 成本配置写入失败不影响耗材保存
        }
      }
    }

    if (mounted) {
      Navigator.of(context).pop(savedId);
      showSnack(context, widget.edit == null ? '已添加耗材' : '已更新耗材');
    }
  }

  // 表单字段统一主题：浅灰填充 + 圆角 + Indigo 聚焦边框。
  // 套在 Theme 上后，TextFormField（厂商 Autocomplete 内部）/ DropdownMenu / InputDecorator 继承。
  // isDark 控制暗色模式色值。
  InputDecorationTheme _fieldTheme(bool isDark) => InputDecorationTheme(
    filled: true,
    fillColor: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
    labelStyle: TextStyle(
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
      fontSize: 13,
    ),
    hintStyle: TextStyle(
      color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
      fontSize: 14,
    ),
    floatingLabelStyle: TextStyle(
      color: AppColors.primary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: BorderSide(
        color: isDark ? AppColors.outlineDark : AppColors.outline,
        width: 1,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: BorderSide(color: AppColors.primary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: const BorderSide(color: AppColors.danger, width: 1),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.edit != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 暗色模式色值切换：文字 / 描边
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textTertiary = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    final outlineColor = isDark ? AppColors.outlineDark : AppColors.outline;
    final loadedCatalog =
        ref.watch(materialCatalogProvider).valueOrNull ??
        MaterialCatalogService.fallbackMaterials;
    final materialCatalog = <String>{_material, ...loadedCatalog}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return SingleChildScrollView(
      child: Theme(
        data: Theme.of(
          context,
        ).copyWith(inputDecorationTheme: _fieldTheme(isDark)),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题区：图标徽章 + 标题 + 副标题
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(AppColors.radiusLg),
                    ),
                    child: Icon(
                      Icons.inventory_2_outlined,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isEdit ? '编辑耗材' : '新增耗材',
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isEdit ? '修改耗材信息' : '填写耗材信息以加入库存',
                          style: TextStyle(color: textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 厂商：Autocomplete（厂商库 = 预设热门 + 已入库厂商）
              Autocomplete<String>(
                initialValue: TextEditingValue(
                  text: _manufacturerController.text,
                ),
                optionsBuilder: (v) {
                  if (v.text.isEmpty) return const Iterable<String>.empty();
                  final input = v.text.toLowerCase();
                  final manufacturers = ref
                      .watch(manufacturersProvider)
                      .maybeWhen(
                        data: (l) => l,
                        orElse: () => PrinterPresets.commonManufacturers,
                      );
                  return manufacturers.where(
                    (m) => m.toLowerCase().contains(input),
                  );
                },
                onSelected: (s) => _autocompleteController?.text = s,
                fieldViewBuilder:
                    (context, controller, focusNode, onSubmitted) {
                      _autocompleteController = controller;
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        onFieldSubmitted: (_) => onSubmitted(),
                        style: TextStyle(color: textPrimary, fontSize: 14),
                        decoration: const InputDecoration(
                          labelText: '厂商 *',
                          hintText: '如 Bambu Lab、Polymaker',
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请输入厂商' : null,
                      );
                    },
              ),
              const SizedBox(height: 14),

              MaterialPickerField(
                label: '耗材型号',
                value: _material,
                onTap: () async {
                  final result = await showMaterialPicker(
                    context: context,
                    materials: materialCatalog,
                    selected: _material,
                  );
                  final value = result?.value;
                  if (!mounted || value == null) return;
                  setState(() {
                    _material = value;
                    // v12：选型号时自动填默认密度（仅当密度为空时，不覆盖用户已填值）
                    if (_densityController.text.trim().isEmpty) {
                      final d = _defaultDensityFor(value);
                      if (d != null) {
                        _densityController.text = d.toStringAsFixed(2);
                      }
                    }
                  });
                },
              ),
              const SizedBox(height: 14),

              // 颜色选择：点击弹出 ColorPickerPanel
              InkWell(
                onTap: _pickColor,
                borderRadius: BorderRadius.circular(AppColors.radiusMd),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: '颜色',
                    suffixIcon: Icon(
                      Icons.color_lens_outlined,
                      color: textTertiary,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: _color,
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusMd,
                          ),
                          border: Border.all(color: outlineColor, width: 1.5),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _colorName.isEmpty
                              ? ColorUtils.toHex(_color)
                              : _colorName,
                          style: TextStyle(color: textPrimary, fontSize: 14),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              if (!isEdit && widget.farmWorkspaceId == null) ...[
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        key: const ValueKey('desktop-entry-rolls-mode'),
                        label: '按卷数入库',
                        compact: true,
                        variant: !_enterRemaining
                            ? AppButtonVariant.primary
                            : AppButtonVariant.secondary,
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _enterRemaining = false;
                                _remainingError = null;
                              }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppButton(
                        key: const ValueKey('desktop-entry-remaining-mode'),
                        label: '按余量入库',
                        compact: true,
                        variant: _enterRemaining
                            ? AppButtonVariant.primary
                            : AppButtonVariant.secondary,
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _enterRemaining = true;
                                _remainingError = null;
                              }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (isEdit && widget.farmWorkspaceId == null)
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '当前库存（编辑信息不改变余量）',
                  ),
                  child: Text(
                    '${GramUtils.formatGrams(widget.edit!.remainingGrams)} / ${GramUtils.formatGrams(widget.edit!.totalGrams)}',
                    style: TextStyle(color: textPrimary, fontSize: 14),
                  ),
                )
              else if (_enterRemaining && widget.farmWorkspaceId == null)
                AppInput(
                  key: const ValueKey('desktop-entry-remaining-grams'),
                  label: '剩余克数（g）',
                  hint: '一卷余料，大于 0 且不超过 1000 g',
                  controller: _remainingController,
                  errorText: _remainingError,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  suffixIcon: Text(
                    'g',
                    style: TextStyle(color: textTertiary, fontSize: 12),
                  ),
                  onChanged: (_) => setState(() => _remainingError = null),
                )
              else ...[
                // Keep the existing stepper, fields and glass interaction style.
                _RollsStepper(
                  value: _rolls,
                  maximum: _maxRolls,
                  controller: _totalDisplayController,
                  onDecrement: () => _changeRolls(-1),
                  onIncrement: () => _changeRolls(1),
                  onInput: _onRollsInput,
                ),
                const SizedBox(height: 6),
                // 总克数预览（卷数 × 1kg/卷）
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    '总克数：${GramUtils.formatGrams(GramUtils.rollsToGrams(_rolls))}'
                    ' · 剩余 ${GramUtils.formatGrams(GramUtils.rollsToGrams(_rolls))}',
                    style: TextStyle(
                      color: textTertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // 单价（元/卷）：填了就同步到耗材成本配置
              // AppInput 自带聚焦光环 + 暗色适配，keyboardType 数字 + 小数
              AppInput(
                label: '单价（元/卷）',
                hint: '可选，填了自动同步到耗材成本',
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                suffixIcon: Text(
                  '元/卷',
                  style: TextStyle(fontSize: 12, color: textTertiary),
                ),
              ),
              const SizedBox(height: 14),

              // v12：耗材物理参数（可选，影响切片重量精度 + 干燥提醒周期）
              // 密度 + 推荐温度横排
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppInput(
                      label: '密度 (g/cm³)',
                      controller: _densityController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppInput(
                      label: '推荐温度 (℃)',
                      controller: _nozzleTempController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AppSelect<String?>(
                value: _hygroscopicity,
                label: '吸湿性（干燥提醒）',
                onChanged: (v) => setState(() => _hygroscopicity = v),
                items: const [
                  DropdownMenuItem(value: null, child: Text('自动（按材质推断）')),
                  DropdownMenuItem(value: 'low', child: Text('低（PLA 等，14天）')),
                  DropdownMenuItem(
                    value: 'medium',
                    child: Text('中（PETG/ABS，7天）'),
                  ),
                  DropdownMenuItem(value: 'high', child: Text('高（TPU/尼龙，3天）')),
                ],
              ),
              const SizedBox(height: 14),

              // 备注（可选）
              AppInput(label: '备注（可选）', controller: _noteController),
              const SizedBox(height: 24),

              // 保存按钮：AppButton primary 全宽
              SizedBox(
                width: double.infinity,
                child: AppButton(
                  label: _saving ? '保存中…' : (isEdit ? '保存修改' : '保存'),
                  icon: const Icon(Icons.check_rounded),
                  // 保存进行中禁用按钮，防止重复提交
                  onPressed: _saving ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卷数 stepper：左侧减号、中间输入框、右侧加号。
/// 以加减号为主，输入框保留手动输入（失焦时同步）。
class _RollsStepper extends StatelessWidget {
  final int value;
  final int maximum;
  final TextEditingController controller;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final ValueChanged<String> onInput;

  const _RollsStepper({
    required this.value,
    required this.maximum,
    required this.controller,
    required this.onDecrement,
    required this.onIncrement,
    required this.onInput,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '卷数',
        suffixText: '卷（1kg/卷）',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Row(
        children: [
          // 减号
          _RoundIconButton(
            icon: Icons.remove_rounded,
            onTap: value > 1 ? onDecrement : null,
          ),
          const SizedBox(width: 8),
          // 输入框（居中显示当前卷数）。filled:false 覆盖主题，避免双重填充。
          Expanded(
            child: TextFormField(
              key: const ValueKey('desktop-entry-roll-count'),
              controller: controller,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: onInput,
              validator: (v) {
                final count = int.tryParse((v ?? '').trim());
                return count == null || count < 1 || count > maximum
                    ? '请输入 1 到 $maximum 的整数卷数'
                    : null;
              },
            ),
          ),
          const SizedBox(width: 8),
          // 加号
          _RoundIconButton(
            icon: Icons.add_rounded,
            onTap: value < maximum ? onIncrement : null,
          ),
        ],
      ),
    );
  }
}

/// 圆形加减号按钮
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox.square(
        dimension: 36,
        child: AppGlassButton(
          tooltip: icon == Icons.add_rounded || icon == Icons.add
              ? '增加卷数'
              : '减少卷数',
          onPressed: onTap,
          variant: AppGlassButtonVariant.secondary,
          compact: true,
          minimumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(20),
          child: Icon(icon, size: 22),
        ),
      );
    }
    return Material(
      color: enabled ? AppColors.primaryContainer : AppColors.surfaceVariant,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 22,
            color: enabled ? AppColors.primary : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}
