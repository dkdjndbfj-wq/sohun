import 'dart:convert';

/// copyWith 的 sentinel 值：用于区分"未传参"和"显式传 null 清空"。
///
/// copyWith 中所有可空字段（description / shareId / avatarUrl / uploadedAt /
/// serverVersion / previewImageUrl）默认值是 `null`，但 `null` 既表示"未传参"
/// 也表示"清空"，语义冲突。引入 [_kUnsent] 后，默认值改为 [_kUnsent]，
/// 调用方传 `null` 表示清空，不传表示保持原值。
const _kUnsent = Object();

/// 打印参数预设模型。
///
/// 对应 Bambu Studio 的 Process Preset（工艺参数预设）。
/// 所有参数字段用 String 类型存储（与 Bambu Studio 一致，如 "0.2"、"150"、"1"）。
///
/// 5 个分类：
/// - [PrintQualityParams] 质量（层高、线宽等）
/// - [PrintStrengthParams] 强度（填充、墙数等）
/// - [PrintSpeedParams] 速度（打印速度、加速度等）
/// - [PrintSupportParams] 支撑（支撑类型、密度等）
/// - [PrintOtherParams] 其他（接缝、熨烫、模糊皮肤等）
class PrintParameterPreset {
  final String id;
  final String name;
  final String? description;
  final String? author;
  final String? material; // PLA/PETG/ABS/TPU 等
  final String? scene; // 场景：手办/功能件/快速打印/超高精度
  final String? plateType; // 打印板类型；旧预设缺失时保持 null（未知）
  final List<String> compatiblePrinters; // 兼容打印机型号/机器预设名
  final DateTime createdAt;
  final DateTime updatedAt;
  final String inherits; // 继承的父预设名，用户自定义预设默认 'fdm_process_common'，导出时若为默认值则置空

  final PrintQualityParams quality;
  final PrintStrengthParams strength;
  final PrintSpeedParams speed;
  final PrintSupportParams support;
  final PrintOtherParams other;

  // ===== 服务器分享相关字段（预留，都可为空或带默认值）=====
  final String? shareId; // 服务器分享 ID（上传后服务器返回，null 表示未上传）
  final String? avatarUrl; // 作者头像 URL（null 时用首字母头像）
  final int likes; // 点赞数
  final int downloads; // 下载次数
  final DateTime? uploadedAt; // 上传时间（null 表示未上传）
  final String? serverVersion; // 服务器版本号（用于版本管理）
  final List<String> tags; // 标签列表（如 ['手办', 'PLA', '高速']）
  final String? previewImageUrl; // 预览图 URL（打印效果展示图）
  final String? communityPublicationId; // 工作台参数广场发布 ID，与拓竹 shareId 完全分离
  final String? communityOwnerId; // 服务端作者 ID
  final int? communityRevision; // 乐观锁版本号
  final String? communityVisibility; // public / unlisted / private

  const PrintParameterPreset({
    required this.id,
    required this.name,
    this.description,
    this.author,
    this.material,
    this.scene,
    this.plateType,
    this.compatiblePrinters = const [],
    required this.createdAt,
    required this.updatedAt,
    this.inherits = 'fdm_process_common',
    required this.quality,
    required this.strength,
    required this.speed,
    required this.support,
    required this.other,
    this.shareId,
    this.avatarUrl,
    this.likes = 0,
    this.downloads = 0,
    this.uploadedAt,
    this.serverVersion,
    this.tags = const [],
    this.previewImageUrl,
    this.communityPublicationId,
    this.communityOwnerId,
    this.communityRevision,
    this.communityVisibility,
  });

  /// 从 .bbsparam 格式的 JSON 字符串导入。
  factory PrintParameterPreset.fromBbsparamJson(String content) {
    final root = jsonDecode(content) as Map<String, dynamic>;
    final preset = root['preset'] as Map<String, dynamic>? ?? {};
    final params = preset['params'] as Map<String, dynamic>? ?? {};
    final now = DateTime.now();
    return PrintParameterPreset(
      id: preset['id'] as String? ?? '',
      name: preset['name'] as String? ?? '未命名',
      description: preset['description'] as String?,
      author: preset['author'] as String?,
      material: preset['material'] as String?,
      scene: preset['scene'] as String?,
      plateType: preset['plateType'] as String?,
      compatiblePrinters: (preset['compatiblePrinters'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      createdAt: preset['createdAt'] != null
          ? DateTime.tryParse(preset['createdAt'] as String) ?? now
          : now,
      updatedAt: preset['updatedAt'] != null
          ? DateTime.tryParse(preset['updatedAt'] as String) ?? now
          : now,
      inherits: preset['inherits'] as String? ?? 'fdm_process_common',
      quality: PrintQualityParams.fromMap(
        params['quality'] as Map<String, dynamic>? ?? {},
      ),
      strength: PrintStrengthParams.fromMap(
        params['strength'] as Map<String, dynamic>? ?? {},
      ),
      speed: PrintSpeedParams.fromMap(
        params['speed'] as Map<String, dynamic>? ?? {},
      ),
      support: PrintSupportParams.fromMap(
        params['support'] as Map<String, dynamic>? ?? {},
      ),
      other: PrintOtherParams.fromMap(
        params['other'] as Map<String, dynamic>? ?? {},
      ),
      shareId: preset['shareId'] as String?,
      avatarUrl: preset['avatarUrl'] as String?,
      likes: preset['likes'] as int? ?? 0,
      downloads: preset['downloads'] as int? ?? 0,
      uploadedAt: preset['uploadedAt'] != null
          ? DateTime.tryParse(preset['uploadedAt'] as String)
          : null,
      serverVersion: preset['serverVersion'] as String?,
      tags: (preset['tags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      previewImageUrl: preset['previewImageUrl'] as String?,
      communityPublicationId: preset['communityPublicationId'] as String?,
      communityOwnerId: preset['communityOwnerId'] as String?,
      communityRevision: (preset['communityRevision'] as num?)?.toInt(),
      communityVisibility: preset['communityVisibility'] as String?,
    );
  }

  PrintParameterPreset copyWith({
    String? id,
    String? name,
    Object? description = _kUnsent,
    String? author,
    String? material,
    String? scene,
    Object? plateType = _kUnsent,
    List<String>? compatiblePrinters,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? inherits,
    PrintQualityParams? quality,
    PrintStrengthParams? strength,
    PrintSpeedParams? speed,
    PrintSupportParams? support,
    PrintOtherParams? other,
    Object? shareId = _kUnsent,
    Object? avatarUrl = _kUnsent,
    int? likes,
    int? downloads,
    Object? uploadedAt = _kUnsent,
    Object? serverVersion = _kUnsent,
    List<String>? tags,
    Object? previewImageUrl = _kUnsent,
    Object? communityPublicationId = _kUnsent,
    Object? communityOwnerId = _kUnsent,
    Object? communityRevision = _kUnsent,
    Object? communityVisibility = _kUnsent,
  }) {
    return PrintParameterPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      // 可空字段：显式传 null 清空，不传保持原值
      description:
          description == _kUnsent ? this.description : description as String?,
      author: author ?? this.author,
      material: material ?? this.material,
      scene: scene ?? this.scene,
      plateType: plateType == _kUnsent ? this.plateType : plateType as String?,
      compatiblePrinters: compatiblePrinters ?? this.compatiblePrinters,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      inherits: inherits ?? this.inherits,
      quality: quality ?? this.quality,
      strength: strength ?? this.strength,
      speed: speed ?? this.speed,
      support: support ?? this.support,
      other: other ?? this.other,
      shareId: shareId == _kUnsent ? this.shareId : shareId as String?,
      avatarUrl: avatarUrl == _kUnsent ? this.avatarUrl : avatarUrl as String?,
      likes: likes ?? this.likes,
      downloads: downloads ?? this.downloads,
      uploadedAt:
          uploadedAt == _kUnsent ? this.uploadedAt : uploadedAt as DateTime?,
      serverVersion: serverVersion == _kUnsent
          ? this.serverVersion
          : serverVersion as String?,
      tags: tags ?? this.tags,
      previewImageUrl: previewImageUrl == _kUnsent
          ? this.previewImageUrl
          : previewImageUrl as String?,
      communityPublicationId: communityPublicationId == _kUnsent
          ? this.communityPublicationId
          : communityPublicationId as String?,
      communityOwnerId: communityOwnerId == _kUnsent
          ? this.communityOwnerId
          : communityOwnerId as String?,
      communityRevision: communityRevision == _kUnsent
          ? this.communityRevision
          : communityRevision as int?,
      communityVisibility: communityVisibility == _kUnsent
          ? this.communityVisibility
          : communityVisibility as String?,
    );
  }

  /// 解除本地草稿与参数广场发布的关联。
  ///
  /// 拓竹云端字段和草稿内容保持不变，草稿之后可作为新内容再次发布。
  PrintParameterPreset withoutCommunityPublication() {
    return copyWith(
      communityPublicationId: null,
      communityOwnerId: null,
      communityRevision: null,
      communityVisibility: null,
    );
  }

  /// 序列化为 .bbsparam 格式的 JSON 字符串（含元信息）。
  Map<String, dynamic> toBbsparamMap() {
    return {
      'format': 'bbsparam',
      'version': '1.0',
      'preset': {
        'id': id,
        'name': name,
        'description': description,
        'author': author,
        'material': material,
        'scene': scene,
        'plateType': plateType,
        'compatiblePrinters': compatiblePrinters,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'inherits': inherits,
        'shareId': shareId,
        'avatarUrl': avatarUrl,
        'likes': likes,
        'downloads': downloads,
        'uploadedAt': uploadedAt?.toIso8601String(),
        'serverVersion': serverVersion,
        'tags': tags,
        'previewImageUrl': previewImageUrl,
        'communityPublicationId': communityPublicationId,
        'communityOwnerId': communityOwnerId,
        'communityRevision': communityRevision,
        'communityVisibility': communityVisibility,
        'params': {
          'quality': quality.toMap(),
          'strength': strength.toMap(),
          'speed': speed.toMap(),
          'support': support.toMap(),
          'other': other.toMap(),
        },
      },
    };
  }

  /// 序列化为 .bbsparam JSON 字符串。
  String toBbsparamJson() {
    return const JsonEncoder.withIndent('  ').convert(toBbsparamMap());
  }
}

// ===== 速度/加速度字段判断 =====

/// 判断字段 key 是否为速度/加速度字段（导出 Bambu Studio JSON 时需转为数组格式）。
///
/// 规则：字段名匹配以下任一模式即为速度字段：
/// - 含 `_speed`（如 inner_wall_speed、travel_speed_z）
/// - 以 `_acceleration` 结尾（如 default_acceleration）
/// - 以 `_acc` 结尾（如 slowdown_start_acc）
/// 排除布尔开关：enable_* 前缀（如 enable_overhang_speed）、
/// _continuous 后缀（如 z_direction_outwall_speed_continuous）。
///
/// 注意：printer_preset.dart 中也有一个同名的 file-private `_isSpeedField`，
/// 但两者逻辑不同（此处的用于 Process 参数，使用 endsWith 匹配；
/// 彼处的用于 Machine 参数，使用 contains 匹配 max_speed_x / max_accel_x 等）。
/// 刻意保持独立，不抽取共享文件。
bool _isSpeedField(String key) {
  if (key.startsWith('enable_')) return false;
  if (key.endsWith('_continuous')) return false;
  return key.contains('_speed') ||
      key.endsWith('_acceleration') ||
      key.endsWith('_acc');
}

/// 把 toMap() 结果（全 String）转为 Bambu Studio JSON 格式（速度字段为数组）。
Map<String, dynamic> _toBambuJson(Map<String, String> map) {
  return map.map((key, value) {
    if (_isSpeedField(key)) {
      return MapEntry(key, [value]);
    }
    return MapEntry(key, value);
  });
}

/// 从动态值解析为字符串（兼容 Bambu Studio 的数组格式 ["0.2"] → "0.2"）。
String _parseStr(dynamic v) {
  if (v == null) return '';
  if (v is List && v.isNotEmpty) {
    return v.first?.toString() ?? '';
  }
  return v.toString();
}

// ===== A. 质量（14 字段）=====

/// 质量参数：层高、线宽等。
class PrintQualityParams {
  final String layerHeight; // layer_height
  final String initialLayerPrintHeight; // initial_layer_print_height
  final String adaptiveLayerHeight; // adaptive_layer_height (0/1)
  final String lineWidth; // line_width
  final String initialLayerLineWidth; // initial_layer_line_width
  final String innerWallLineWidth; // inner_wall_line_width
  final String outerWallLineWidth; // outer_wall_line_width
  final String topSurfaceLineWidth; // top_surface_line_width
  final String sparseInfillLineWidth; // sparse_infill_line_width
  final String skinInfillLineWidth; // skin_infill_line_width
  final String skeletonInfillLineWidth; // skeleton_infill_line_width
  final String internalSolidInfillLineWidth; // internal_solid_infill_line_width
  final String supportLineWidth; // support_line_width
  final String resolution; // resolution

  const PrintQualityParams({
    this.layerHeight = '0.2',
    this.initialLayerPrintHeight = '0.2',
    this.adaptiveLayerHeight = '0',
    this.lineWidth = '0.42',
    this.initialLayerLineWidth = '0.5',
    this.innerWallLineWidth = '0.45',
    this.outerWallLineWidth = '0.42',
    this.topSurfaceLineWidth = '0.42',
    this.sparseInfillLineWidth = '0.45',
    this.skinInfillLineWidth = '0.42',
    this.skeletonInfillLineWidth = '0.42',
    this.internalSolidInfillLineWidth = '0.42',
    this.supportLineWidth = '0.42',
    this.resolution = '0.0125',
  });

  Map<String, String> toMap() => {
        'layer_height': layerHeight,
        'initial_layer_print_height': initialLayerPrintHeight,
        'adaptive_layer_height': adaptiveLayerHeight,
        'line_width': lineWidth,
        'initial_layer_line_width': initialLayerLineWidth,
        'inner_wall_line_width': innerWallLineWidth,
        'outer_wall_line_width': outerWallLineWidth,
        'top_surface_line_width': topSurfaceLineWidth,
        'sparse_infill_line_width': sparseInfillLineWidth,
        'skin_infill_line_width': skinInfillLineWidth,
        'skeleton_infill_line_width': skeletonInfillLineWidth,
        'internal_solid_infill_line_width': internalSolidInfillLineWidth,
        'support_line_width': supportLineWidth,
        'resolution': resolution,
      };

  Map<String, dynamic> toJson() => _toBambuJson(toMap());

  factory PrintQualityParams.fromMap(Map<String, dynamic> map) {
    return PrintQualityParams(
      layerHeight: _parseStr(map['layer_height']),
      initialLayerPrintHeight: _parseStr(map['initial_layer_print_height']),
      adaptiveLayerHeight: _parseStr(map['adaptive_layer_height']),
      lineWidth: _parseStr(map['line_width']),
      initialLayerLineWidth: _parseStr(map['initial_layer_line_width']),
      innerWallLineWidth: _parseStr(map['inner_wall_line_width']),
      outerWallLineWidth: _parseStr(map['outer_wall_line_width']),
      topSurfaceLineWidth: _parseStr(map['top_surface_line_width']),
      sparseInfillLineWidth: _parseStr(map['sparse_infill_line_width']),
      skinInfillLineWidth: _parseStr(map['skin_infill_line_width']),
      skeletonInfillLineWidth: _parseStr(map['skeleton_infill_line_width']),
      internalSolidInfillLineWidth:
          _parseStr(map['internal_solid_infill_line_width']),
      supportLineWidth: _parseStr(map['support_line_width']),
      resolution: _parseStr(map['resolution']),
    );
  }
}

// ===== B. 强度（34 字段）=====

/// 强度参数：填充、墙数等。
class PrintStrengthParams {
  final String wallLoops; // wall_loops
  final String topShellLayers; // top_shell_layers
  final String bottomShellLayers; // bottom_shell_layers
  final String topShellThickness; // top_shell_thickness
  final String bottomShellThickness; // bottom_shell_thickness
  final String topColorPenetrationLayers; // top_color_penetration_layers
  final String bottomColorPenetrationLayers; // bottom_color_penetration_layers
  final String sparseInfillDensity; // sparse_infill_density
  final String skeletonInfillDensity; // skeleton_infill_density
  final String skinInfillDensity; // skin_infill_density
  final String skinInfillDepth; // skin_infill_depth
  final String sparseInfillPattern; // sparse_infill_pattern
  final String lockedSkinInfillPattern; // locked_skin_infill_pattern
  final String lockedSkeletonInfillPattern; // locked_skeleton_infill_pattern
  final String infillCombination; // infill_combination
  final String infillDirection; // infill_direction
  final String infillWallOverlap; // infill_wall_overlap
  final String infillLockDepth; // infill_lock_depth
  final String infillShiftStep; // infill_shift_step
  final String infillRotateStep; // infill_rotate_step
  final String minimumSparseInfillArea; // minimum_sparse_infill_area
  final String
      infillInsteadTopBottomSurfaces; // infill_instead_top_bottom_surfaces (0/1)
  final String sparseInfillFilament; // sparse_infill_filament
  final String wallFilament; // wall_filament
  final String solidInfillFilament; // solid_infill_filament
  final String interfaceShells; // interface_shells (0/1)
  final String
      detectFloatingVerticalShell; // detect_floating_vertical_shell (0/1)
  final String detectOverhangWall; // detect_overhang_wall (0/1)
  final String detectThinWall; // detect_thin_wall (0/1)
  final String onlyOneWallTop; // only_one_wall_top (0/1)
  final String fillMultiline; // fill_multiline (0/1)
  final String sparseInfillLatticeAngle1; // sparse_infill_lattice_angle_1
  final String sparseInfillLatticeAngle2; // sparse_infill_lattice_angle_2
  final String symmetricInfillYAxis; // symmetric_infill_y_axis (0/1)

  const PrintStrengthParams({
    this.wallLoops = '2',
    this.topShellLayers = '4',
    this.bottomShellLayers = '4',
    this.topShellThickness = '0.8',
    this.bottomShellThickness = '0.8',
    this.topColorPenetrationLayers = '0',
    this.bottomColorPenetrationLayers = '0',
    this.sparseInfillDensity = '15%',
    this.skeletonInfillDensity = '0%',
    this.skinInfillDensity = '0%',
    this.skinInfillDepth = '0',
    this.sparseInfillPattern = 'grid',
    this.lockedSkinInfillPattern = 'concentric',
    this.lockedSkeletonInfillPattern = 'concentric',
    this.infillCombination = '0',
    this.infillDirection = '45',
    this.infillWallOverlap = '15%',
    this.infillLockDepth = '3',
    this.infillShiftStep = '0.2',
    this.infillRotateStep = '0.2',
    this.minimumSparseInfillArea = '0',
    this.infillInsteadTopBottomSurfaces = '0',
    this.sparseInfillFilament = '1',
    this.wallFilament = '1',
    this.solidInfillFilament = '1',
    this.interfaceShells = '0',
    this.detectFloatingVerticalShell = '1',
    this.detectOverhangWall = '1',
    this.detectThinWall = '0',
    this.onlyOneWallTop = '0',
    this.fillMultiline = '1',
    this.sparseInfillLatticeAngle1 = '30',
    this.sparseInfillLatticeAngle2 = '90',
    this.symmetricInfillYAxis = '0',
  });

  Map<String, String> toMap() => {
        'wall_loops': wallLoops,
        'top_shell_layers': topShellLayers,
        'bottom_shell_layers': bottomShellLayers,
        'top_shell_thickness': topShellThickness,
        'bottom_shell_thickness': bottomShellThickness,
        'top_color_penetration_layers': topColorPenetrationLayers,
        'bottom_color_penetration_layers': bottomColorPenetrationLayers,
        'sparse_infill_density': sparseInfillDensity,
        'skeleton_infill_density': skeletonInfillDensity,
        'skin_infill_density': skinInfillDensity,
        'skin_infill_depth': skinInfillDepth,
        'sparse_infill_pattern': sparseInfillPattern,
        'locked_skin_infill_pattern': lockedSkinInfillPattern,
        'locked_skeleton_infill_pattern': lockedSkeletonInfillPattern,
        'infill_combination': infillCombination,
        'infill_direction': infillDirection,
        'infill_wall_overlap': infillWallOverlap,
        'infill_lock_depth': infillLockDepth,
        'infill_shift_step': infillShiftStep,
        'infill_rotate_step': infillRotateStep,
        'minimum_sparse_infill_area': minimumSparseInfillArea,
        'infill_instead_top_bottom_surfaces': infillInsteadTopBottomSurfaces,
        'sparse_infill_filament': sparseInfillFilament,
        'wall_filament': wallFilament,
        'solid_infill_filament': solidInfillFilament,
        'interface_shells': interfaceShells,
        'detect_floating_vertical_shell': detectFloatingVerticalShell,
        'detect_overhang_wall': detectOverhangWall,
        'detect_thin_wall': detectThinWall,
        'only_one_wall_top': onlyOneWallTop,
        'fill_multiline': fillMultiline,
        'sparse_infill_lattice_angle_1': sparseInfillLatticeAngle1,
        'sparse_infill_lattice_angle_2': sparseInfillLatticeAngle2,
        'symmetric_infill_y_axis': symmetricInfillYAxis,
      };

  Map<String, dynamic> toJson() => _toBambuJson(toMap());

  factory PrintStrengthParams.fromMap(Map<String, dynamic> map) {
    return PrintStrengthParams(
      wallLoops: _parseStr(map['wall_loops']),
      topShellLayers: _parseStr(map['top_shell_layers']),
      bottomShellLayers: _parseStr(map['bottom_shell_layers']),
      topShellThickness: _parseStr(map['top_shell_thickness']),
      bottomShellThickness: _parseStr(map['bottom_shell_thickness']),
      topColorPenetrationLayers: _parseStr(map['top_color_penetration_layers']),
      bottomColorPenetrationLayers:
          _parseStr(map['bottom_color_penetration_layers']),
      sparseInfillDensity: _parseStr(map['sparse_infill_density']),
      skeletonInfillDensity: _parseStr(map['skeleton_infill_density']),
      skinInfillDensity: _parseStr(map['skin_infill_density']),
      skinInfillDepth: _parseStr(map['skin_infill_depth']),
      sparseInfillPattern: _parseStr(map['sparse_infill_pattern']),
      lockedSkinInfillPattern: _parseStr(map['locked_skin_infill_pattern']),
      lockedSkeletonInfillPattern:
          _parseStr(map['locked_skeleton_infill_pattern']),
      infillCombination: _parseStr(map['infill_combination']),
      infillDirection: _parseStr(map['infill_direction']),
      infillWallOverlap: _parseStr(map['infill_wall_overlap']),
      infillLockDepth: _parseStr(map['infill_lock_depth']),
      infillShiftStep: _parseStr(map['infill_shift_step']),
      infillRotateStep: _parseStr(map['infill_rotate_step']),
      minimumSparseInfillArea: _parseStr(map['minimum_sparse_infill_area']),
      infillInsteadTopBottomSurfaces:
          _parseStr(map['infill_instead_top_bottom_surfaces']),
      sparseInfillFilament: _parseStr(map['sparse_infill_filament']),
      wallFilament: _parseStr(map['wall_filament']),
      solidInfillFilament: _parseStr(map['solid_infill_filament']),
      interfaceShells: _parseStr(map['interface_shells']),
      detectFloatingVerticalShell:
          _parseStr(map['detect_floating_vertical_shell']),
      detectOverhangWall: _parseStr(map['detect_overhang_wall']),
      detectThinWall: _parseStr(map['detect_thin_wall']),
      onlyOneWallTop: _parseStr(map['only_one_wall_top']),
      fillMultiline: _parseStr(map['fill_multiline']),
      sparseInfillLatticeAngle1:
          _parseStr(map['sparse_infill_lattice_angle_1']),
      sparseInfillLatticeAngle2:
          _parseStr(map['sparse_infill_lattice_angle_2']),
      symmetricInfillYAxis: _parseStr(map['symmetric_infill_y_axis']),
    );
  }
}

// ===== C. 速度（43 字段）=====

/// 速度参数：打印速度、加速度等。
/// 注意：速度/加速度字段在导出 Bambu Studio JSON 时会自动转为数组格式 ["value"]。
class PrintSpeedParams {
  final String innerWallSpeed; // inner_wall_speed [速度]
  final String outerWallSpeed; // outer_wall_speed [速度]
  final String sparseInfillSpeed; // sparse_infill_speed [速度]
  final String internalSolidInfillSpeed; // internal_solid_infill_speed [速度]
  final String topSurfaceSpeed; // top_surface_speed [速度]
  final String initialLayerSpeed; // initial_layer_speed [速度]
  final String initialLayerInfillSpeed; // initial_layer_infill_speed [速度]
  final String supportSpeed; // support_speed [速度]
  final String supportInterfaceSpeed; // support_interface_speed [速度]
  final String bridgeSpeed; // bridge_speed [速度]
  final String gapInfillSpeed; // gap_infill_speed [速度]
  final String travelSpeed; // travel_speed [速度]
  final String travelSpeedZ; // travel_speed_z [速度]
  final String overhangTotallySpeed; // overhang_totally_speed [速度]
  final String overhang14Speed; // overhang_1_4_speed [速度]
  final String overhang24Speed; // overhang_2_4_speed [速度]
  final String overhang34Speed; // overhang_3_4_speed [速度]
  final String overhang44Speed; // overhang_4_4_speed [速度]
  final String smallPerimeterSpeed; // small_perimeter_speed [速度]
  final String smallPerimeterThreshold; // small_perimeter_threshold
  final String verticalShellSpeed; // vertical_shell_speed [速度]
  final String defaultAcceleration; // default_acceleration [加速度]
  final String travelAcceleration; // travel_acceleration [加速度]
  final String
      travelShortDistanceAcceleration; // travel_short_distance_acceleration [加速度]
  final String initialLayerAcceleration; // initial_layer_acceleration [加速度]
  final String
      initialLayerTravelAcceleration; // initial_layer_travel_acceleration [加速度]
  final String innerWallAcceleration; // inner_wall_acceleration [加速度]
  final String outerWallAcceleration; // outer_wall_acceleration [加速度]
  final String sparseInfillAcceleration; // sparse_infill_acceleration [加速度]
  final String topSurfaceAcceleration; // top_surface_acceleration [加速度]
  final String slowdownStartHeight; // slowdown_start_height [减速]
  final String slowdownStartSpeed; // slowdown_start_speed [减速]
  final String slowdownStartAcc; // slowdown_start_acc [减速]
  final String slowdownEndHeight; // slowdown_end_height [减速]
  final String slowdownEndSpeed; // slowdown_end_speed [减速]
  final String slowdownEndAcc; // slowdown_end_acc [减速]
  final String enableOverhangSpeed; // enable_overhang_speed (0/1)
  final String enableHeightSlowdown; // enable_height_slowdown (0/1)
  final String smoothCoefficient; // smooth_coefficient
  final String layerTimeSmoothing; // layer_time_smoothing
  final String layerTimeSmoothingThreshold; // layer_time_smoothing_threshold
  final String standbyTemperatureDelta; // standby_temperature_delta
  final String preStartFanTime; // pre_start_fan_time

  const PrintSpeedParams({
    this.innerWallSpeed = '150',
    this.outerWallSpeed = '100',
    this.sparseInfillSpeed = '200',
    this.internalSolidInfillSpeed = '200',
    this.topSurfaceSpeed = '100',
    this.initialLayerSpeed = '30',
    this.initialLayerInfillSpeed = '60',
    this.supportSpeed = '80',
    this.supportInterfaceSpeed = '40',
    this.bridgeSpeed = '25',
    this.gapInfillSpeed = '30',
    this.travelSpeed = '300',
    this.travelSpeedZ = '20',
    this.overhangTotallySpeed = '15',
    this.overhang14Speed = '0',
    this.overhang24Speed = '0',
    this.overhang34Speed = '0',
    this.overhang44Speed = '0',
    this.smallPerimeterSpeed = '50%',
    this.smallPerimeterThreshold = '0',
    this.verticalShellSpeed = '120',
    this.defaultAcceleration = '3000',
    this.travelAcceleration = '3000',
    this.travelShortDistanceAcceleration = '3000',
    this.initialLayerAcceleration = '500',
    this.initialLayerTravelAcceleration = '1500',
    this.innerWallAcceleration = '2000',
    this.outerWallAcceleration = '1500',
    this.sparseInfillAcceleration = '3000',
    this.topSurfaceAcceleration = '1000',
    this.slowdownStartHeight = '0.6',
    this.slowdownStartSpeed = '50',
    this.slowdownStartAcc = '1000',
    this.slowdownEndHeight = '0.2',
    this.slowdownEndSpeed = '10',
    this.slowdownEndAcc = '300',
    this.enableOverhangSpeed = '1',
    this.enableHeightSlowdown = '0',
    this.smoothCoefficient = '50%',
    this.layerTimeSmoothing = '10',
    this.layerTimeSmoothingThreshold = '3',
    this.standbyTemperatureDelta = '-5',
    this.preStartFanTime = '0',
  });

  Map<String, String> toMap() => {
        'inner_wall_speed': innerWallSpeed,
        'outer_wall_speed': outerWallSpeed,
        'sparse_infill_speed': sparseInfillSpeed,
        'internal_solid_infill_speed': internalSolidInfillSpeed,
        'top_surface_speed': topSurfaceSpeed,
        'initial_layer_speed': initialLayerSpeed,
        'initial_layer_infill_speed': initialLayerInfillSpeed,
        'support_speed': supportSpeed,
        'support_interface_speed': supportInterfaceSpeed,
        'bridge_speed': bridgeSpeed,
        'gap_infill_speed': gapInfillSpeed,
        'travel_speed': travelSpeed,
        'travel_speed_z': travelSpeedZ,
        'overhang_totally_speed': overhangTotallySpeed,
        'overhang_1_4_speed': overhang14Speed,
        'overhang_2_4_speed': overhang24Speed,
        'overhang_3_4_speed': overhang34Speed,
        'overhang_4_4_speed': overhang44Speed,
        'small_perimeter_speed': smallPerimeterSpeed,
        'small_perimeter_threshold': smallPerimeterThreshold,
        'vertical_shell_speed': verticalShellSpeed,
        'default_acceleration': defaultAcceleration,
        'travel_acceleration': travelAcceleration,
        'travel_short_distance_acceleration': travelShortDistanceAcceleration,
        'initial_layer_acceleration': initialLayerAcceleration,
        'initial_layer_travel_acceleration': initialLayerTravelAcceleration,
        'inner_wall_acceleration': innerWallAcceleration,
        'outer_wall_acceleration': outerWallAcceleration,
        'sparse_infill_acceleration': sparseInfillAcceleration,
        'top_surface_acceleration': topSurfaceAcceleration,
        'slowdown_start_height': slowdownStartHeight,
        'slowdown_start_speed': slowdownStartSpeed,
        'slowdown_start_acc': slowdownStartAcc,
        'slowdown_end_height': slowdownEndHeight,
        'slowdown_end_speed': slowdownEndSpeed,
        'slowdown_end_acc': slowdownEndAcc,
        'enable_overhang_speed': enableOverhangSpeed,
        'enable_height_slowdown': enableHeightSlowdown,
        'smooth_coefficient': smoothCoefficient,
        'layer_time_smoothing': layerTimeSmoothing,
        'layer_time_smoothing_threshold': layerTimeSmoothingThreshold,
        'standby_temperature_delta': standbyTemperatureDelta,
        'pre_start_fan_time': preStartFanTime,
      };

  Map<String, dynamic> toJson() => _toBambuJson(toMap());

  factory PrintSpeedParams.fromMap(Map<String, dynamic> map) {
    return PrintSpeedParams(
      innerWallSpeed: _parseStr(map['inner_wall_speed']),
      outerWallSpeed: _parseStr(map['outer_wall_speed']),
      sparseInfillSpeed: _parseStr(map['sparse_infill_speed']),
      internalSolidInfillSpeed: _parseStr(map['internal_solid_infill_speed']),
      topSurfaceSpeed: _parseStr(map['top_surface_speed']),
      initialLayerSpeed: _parseStr(map['initial_layer_speed']),
      initialLayerInfillSpeed: _parseStr(map['initial_layer_infill_speed']),
      supportSpeed: _parseStr(map['support_speed']),
      supportInterfaceSpeed: _parseStr(map['support_interface_speed']),
      bridgeSpeed: _parseStr(map['bridge_speed']),
      gapInfillSpeed: _parseStr(map['gap_infill_speed']),
      travelSpeed: _parseStr(map['travel_speed']),
      travelSpeedZ: _parseStr(map['travel_speed_z']),
      overhangTotallySpeed: _parseStr(map['overhang_totally_speed']),
      overhang14Speed: _parseStr(map['overhang_1_4_speed']),
      overhang24Speed: _parseStr(map['overhang_2_4_speed']),
      overhang34Speed: _parseStr(map['overhang_3_4_speed']),
      overhang44Speed: _parseStr(map['overhang_4_4_speed']),
      smallPerimeterSpeed: _parseStr(map['small_perimeter_speed']),
      smallPerimeterThreshold: _parseStr(map['small_perimeter_threshold']),
      verticalShellSpeed: _parseStr(map['vertical_shell_speed']),
      defaultAcceleration: _parseStr(map['default_acceleration']),
      travelAcceleration: _parseStr(map['travel_acceleration']),
      travelShortDistanceAcceleration:
          _parseStr(map['travel_short_distance_acceleration']),
      initialLayerAcceleration: _parseStr(map['initial_layer_acceleration']),
      initialLayerTravelAcceleration:
          _parseStr(map['initial_layer_travel_acceleration']),
      innerWallAcceleration: _parseStr(map['inner_wall_acceleration']),
      outerWallAcceleration: _parseStr(map['outer_wall_acceleration']),
      sparseInfillAcceleration: _parseStr(map['sparse_infill_acceleration']),
      topSurfaceAcceleration: _parseStr(map['top_surface_acceleration']),
      slowdownStartHeight: _parseStr(map['slowdown_start_height']),
      slowdownStartSpeed: _parseStr(map['slowdown_start_speed']),
      slowdownStartAcc: _parseStr(map['slowdown_start_acc']),
      slowdownEndHeight: _parseStr(map['slowdown_end_height']),
      slowdownEndSpeed: _parseStr(map['slowdown_end_speed']),
      slowdownEndAcc: _parseStr(map['slowdown_end_acc']),
      enableOverhangSpeed: _parseStr(map['enable_overhang_speed']),
      enableHeightSlowdown: _parseStr(map['enable_height_slowdown']),
      smoothCoefficient: _parseStr(map['smooth_coefficient']),
      layerTimeSmoothing: _parseStr(map['layer_time_smoothing']),
      layerTimeSmoothingThreshold:
          _parseStr(map['layer_time_smoothing_threshold']),
      standbyTemperatureDelta: _parseStr(map['standby_temperature_delta']),
      preStartFanTime: _parseStr(map['pre_start_fan_time']),
    );
  }
}

// ===== D. 支撑（32 字段）=====

/// 支撑参数：支撑类型、密度等。
class PrintSupportParams {
  final String enableSupport; // enable_support (0/1)
  final String supportType; // support_type
  final String supportStyle; // support_style
  final String supportThresholdAngle; // support_threshold_angle
  final String supportOnBuildPlateOnly; // support_on_build_plate_only (0/1)
  final String supportBasePattern; // support_base_pattern
  final String supportBasePatternSpacing; // support_base_pattern_spacing
  final String supportExpansion; // support_expansion
  final String supportFilament; // support_filament
  final String supportInterfaceFilament; // support_interface_filament
  final String supportInterfacePattern; // support_interface_pattern
  final String supportInterfaceSpacing; // support_interface_spacing
  final String
      supportInterfaceLoopPattern; // support_interface_loop_pattern (0/1)
  final String supportInterfaceTopLayers; // support_interface_top_layers
  final String supportInterfaceBottomLayers; // support_interface_bottom_layers
  final String supportTopZDistance; // support_top_z_distance
  final String supportBottomZDistance; // support_bottom_z_distance
  final String supportObjectXyDistance; // support_object_xy_distance
  final String treeSupportBranchAngle; // tree_support_branch_angle
  final String treeSupportBranchDiameter; // tree_support_branch_diameter
  final String treeSupportWallCount; // tree_support_wall_count
  final String raftLayers; // raft_layers
  final String bridgeNoSupport; // bridge_no_support (0/1)
  final String maxBridgeLength; // max_bridge_length
  final String
      internalBridgeSupportThickness; // internal_bridge_support_thickness
  final String enableSupportIroning; // enable_support_ironing (0/1)
  final String supportIroningPattern; // support_ironing_pattern
  final String supportIroningSpeed; // support_ironing_speed [速度]
  final String supportIroningFlow; // support_ironing_flow
  final String supportIroningSpacing; // support_ironing_spacing
  final String supportIroningInset; // support_ironing_inset
  final String supportIroningDirection; // support_ironing_direction

  const PrintSupportParams({
    this.enableSupport = '1',
    this.supportType = 'tree(auto)',
    this.supportStyle = 'default',
    this.supportThresholdAngle = '30',
    this.supportOnBuildPlateOnly = '0',
    this.supportBasePattern = 'default',
    this.supportBasePatternSpacing = '2',
    this.supportExpansion = '0%',
    this.supportFilament = '1',
    this.supportInterfaceFilament = '1',
    this.supportInterfacePattern = 'concentric',
    this.supportInterfaceSpacing = '0.5',
    this.supportInterfaceLoopPattern = '0',
    this.supportInterfaceTopLayers = '2',
    this.supportInterfaceBottomLayers = '2',
    this.supportTopZDistance = '0.2',
    this.supportBottomZDistance = '0.2',
    this.supportObjectXyDistance = '0.35',
    this.treeSupportBranchAngle = '30',
    this.treeSupportBranchDiameter = '5',
    this.treeSupportWallCount = '1',
    this.raftLayers = '0',
    this.bridgeNoSupport = '0',
    this.maxBridgeLength = '5',
    this.internalBridgeSupportThickness = '0.5',
    this.enableSupportIroning = '0',
    this.supportIroningPattern = 'rectilinear',
    this.supportIroningSpeed = '20',
    this.supportIroningFlow = '20%',
    this.supportIroningSpacing = '0.1',
    this.supportIroningInset = '0.1',
    this.supportIroningDirection = '0',
  });

  Map<String, String> toMap() => {
        'enable_support': enableSupport,
        'support_type': supportType,
        'support_style': supportStyle,
        'support_threshold_angle': supportThresholdAngle,
        'support_on_build_plate_only': supportOnBuildPlateOnly,
        'support_base_pattern': supportBasePattern,
        'support_base_pattern_spacing': supportBasePatternSpacing,
        'support_expansion': supportExpansion,
        'support_filament': supportFilament,
        'support_interface_filament': supportInterfaceFilament,
        'support_interface_pattern': supportInterfacePattern,
        'support_interface_spacing': supportInterfaceSpacing,
        'support_interface_loop_pattern': supportInterfaceLoopPattern,
        'support_interface_top_layers': supportInterfaceTopLayers,
        'support_interface_bottom_layers': supportInterfaceBottomLayers,
        'support_top_z_distance': supportTopZDistance,
        'support_bottom_z_distance': supportBottomZDistance,
        'support_object_xy_distance': supportObjectXyDistance,
        'tree_support_branch_angle': treeSupportBranchAngle,
        'tree_support_branch_diameter': treeSupportBranchDiameter,
        'tree_support_wall_count': treeSupportWallCount,
        'raft_layers': raftLayers,
        'bridge_no_support': bridgeNoSupport,
        'max_bridge_length': maxBridgeLength,
        'internal_bridge_support_thickness': internalBridgeSupportThickness,
        'enable_support_ironing': enableSupportIroning,
        'support_ironing_pattern': supportIroningPattern,
        'support_ironing_speed': supportIroningSpeed,
        'support_ironing_flow': supportIroningFlow,
        'support_ironing_spacing': supportIroningSpacing,
        'support_ironing_inset': supportIroningInset,
        'support_ironing_direction': supportIroningDirection,
      };

  Map<String, dynamic> toJson() => _toBambuJson(toMap());

  factory PrintSupportParams.fromMap(Map<String, dynamic> map) {
    return PrintSupportParams(
      enableSupport: _parseStr(map['enable_support']),
      supportType: _parseStr(map['support_type']),
      supportStyle: _parseStr(map['support_style']),
      supportThresholdAngle: _parseStr(map['support_threshold_angle']),
      supportOnBuildPlateOnly: _parseStr(map['support_on_build_plate_only']),
      supportBasePattern: _parseStr(map['support_base_pattern']),
      supportBasePatternSpacing: _parseStr(map['support_base_pattern_spacing']),
      supportExpansion: _parseStr(map['support_expansion']),
      supportFilament: _parseStr(map['support_filament']),
      supportInterfaceFilament: _parseStr(map['support_interface_filament']),
      supportInterfacePattern: _parseStr(map['support_interface_pattern']),
      supportInterfaceSpacing: _parseStr(map['support_interface_spacing']),
      supportInterfaceLoopPattern:
          _parseStr(map['support_interface_loop_pattern']),
      supportInterfaceTopLayers: _parseStr(map['support_interface_top_layers']),
      supportInterfaceBottomLayers:
          _parseStr(map['support_interface_bottom_layers']),
      supportTopZDistance: _parseStr(map['support_top_z_distance']),
      supportBottomZDistance: _parseStr(map['support_bottom_z_distance']),
      supportObjectXyDistance: _parseStr(map['support_object_xy_distance']),
      treeSupportBranchAngle: _parseStr(map['tree_support_branch_angle']),
      treeSupportBranchDiameter: _parseStr(map['tree_support_branch_diameter']),
      treeSupportWallCount: _parseStr(map['tree_support_wall_count']),
      raftLayers: _parseStr(map['raft_layers']),
      bridgeNoSupport: _parseStr(map['bridge_no_support']),
      maxBridgeLength: _parseStr(map['max_bridge_length']),
      internalBridgeSupportThickness:
          _parseStr(map['internal_bridge_support_thickness']),
      enableSupportIroning: _parseStr(map['enable_support_ironing']),
      supportIroningPattern: _parseStr(map['support_ironing_pattern']),
      supportIroningSpeed: _parseStr(map['support_ironing_speed']),
      supportIroningFlow: _parseStr(map['support_ironing_flow']),
      supportIroningSpacing: _parseStr(map['support_ironing_spacing']),
      supportIroningInset: _parseStr(map['support_ironing_inset']),
      supportIroningDirection: _parseStr(map['support_ironing_direction']),
    );
  }
}

// ===== E. 其他（68 字段）=====

/// 其他参数：接缝、熨烫、模糊皮肤、 prime tower 等。
class PrintOtherParams {
  final String seamPosition; // seam_position
  final String
      seamPlacementAwayFromOverhangs; // seam_placement_away_from_overhangs (0/1)
  final String seamSlopeType; // seam_slope_type
  final String seamSlopeStartHeight; // seam_slope_start_height
  final String seamSlopeGap; // seam_slope_gap
  final String seamSlopeMinLength; // seam_slope_min_length
  final String scarfAngleThreshold; // scarf_angle_threshold
  final String
      overrideFilamentScarfSeamSetting; // override_filament_scarf_seam_setting (0/1)
  final String wallGenerator; // wall_generator
  final String wallInfillOrder; // wall_infill_order
  final String
      zDirectionOutwallSpeedContinuous; // z_direction_outwall_speed_continuous (0/1)
  final String brimWidth; // brim_width
  final String brimObjectGap; // brim_object_gap
  final String brimType; // brim_type
  final String skirtDistance; // skirt_distance
  final String skirtHeight; // skirt_height
  final String skirtLoops; // skirt_loops
  final String skirtPerObject; // skirt_per_object (0/1)
  final String ironingInset; // ironing_inset
  final String ironingSpacing; // ironing_spacing
  final String ironingSpeed; // ironing_speed [速度]
  final String ironingType; // ironing_type
  final String enablePrimeTower; // enable_prime_tower (0/1)
  final String primeTowerWidth; // prime_tower_width
  final String primeTowerBrimWidth; // prime_tower_brim_width
  final String primeTowerEnableFramework; // prime_tower_enable_framework (0/1)
  final String primeTowerLiftSpeed; // prime_tower_lift_speed [速度]
  final String primeTowerLiftHeight; // prime_tower_lift_height
  final String primeTowerMaxSpeed; // prime_tower_max_speed [速度]
  final String primeTowerFlatIroning; // prime_tower_flat_ironing (0/1)
  final String primeTowerInfillGap; // prime_tower_infill_gap
  final String primeTowerRibWall; // prime_tower_rib_wall
  final String wipeTowerNoSparseLayers; // wipe_tower_no_sparse_layers (0/1)
  final String
      enableTowerInterfaceFeatures; // enable_tower_interface_features (0/1)
  final String spiralMode; // spiral_mode (0/1)
  final String draftShield; // draft_shield
  final String elefantFootCompensation; // elefant_foot_compensation
  final String xyContourCompensation; // xy_contour_compensation
  final String xyHoleCompensation; // xy_hole_compensation
  final String
      circleCompensationManualOffset; // circle_compensation_manual_offset
  final String enableCircleCompensation; // enable_circle_compensation (0/1)
  final String enableWrappingDetection; // enable_wrapping_detection (0/1)
  final String enableArcFitting; // enable_arc_fitting (0/1)
  final String reduceCrossingWall; // reduce_crossing_wall (0/1)
  final String
      avoidCrossingWallIncludesSupport; // avoid_crossing_wall_includes_support (0/1)
  final String reduceInfillRetractionMode; // reduce_infill_retraction_mode
  final String maxTravelDetourDistance; // max_travel_detour_distance
  final String filenameFormat; // filename_format
  final String printSequence; // print_sequence
  final String printExtruderId; // print_extruder_id
  final String printExtruderVariant; // print_extruder_variant
  final String fuzzySkin; // fuzzy_skin
  final String fuzzySkinThickness; // fuzzy_skin_thickness
  final String fuzzySkinPointDistance; // fuzzy_skin_point_distance
  final String fuzzySkinFirstLayer; // fuzzy_skin_first_layer (0/1)
  final String fuzzySkinNoiseType; // fuzzy_skin_noise_type
  final String fuzzySkinMode; // fuzzy_skin_mode
  final String fuzzySkinScale; // fuzzy_skin_scale
  final String fuzzySkinOctaves; // fuzzy_skin_octaves
  final String fuzzySkinPersistence; // fuzzy_skin_persistence
  final String monotonicTravelIntoWall; // monotonic_travel_into_wall (0/1)
  final String topSurfacePattern; // top_surface_pattern
  final String topSurfaceDensity; // top_surface_density
  final String bottomSurfacePattern; // bottom_surface_pattern
  final String bottomSurfaceDensity; // bottom_surface_density
  final String bridgeFlow; // bridge_flow
  final String topSolidInfillFlowRatio; // top_solid_infill_flow_ratio
  final String ironingFlow; // ironing_flow

  const PrintOtherParams({
    this.seamPosition = 'nearest',
    this.seamPlacementAwayFromOverhangs = '0',
    this.seamSlopeType = 'none',
    this.seamSlopeStartHeight = '0.2',
    this.seamSlopeGap = '0.1',
    this.seamSlopeMinLength = '1',
    this.scarfAngleThreshold = '0',
    this.overrideFilamentScarfSeamSetting = '0',
    this.wallGenerator = 'arachne',
    this.wallInfillOrder = 'inner wall/outer wall/infill',
    this.zDirectionOutwallSpeedContinuous = '0',
    this.brimWidth = '0',
    this.brimObjectGap = '0',
    this.brimType = 'outer_and_inner',
    this.skirtDistance = '3',
    this.skirtHeight = '1',
    this.skirtLoops = '1',
    this.skirtPerObject = '0',
    this.ironingInset = '0.1',
    this.ironingSpacing = '0.1',
    this.ironingSpeed = '20',
    this.ironingType = 'no ironing',
    this.enablePrimeTower = '0',
    this.primeTowerWidth = '20',
    this.primeTowerBrimWidth = '0',
    this.primeTowerEnableFramework = '0',
    this.primeTowerLiftSpeed = '20',
    this.primeTowerLiftHeight = '0.6',
    this.primeTowerMaxSpeed = '200',
    this.primeTowerFlatIroning = '0',
    this.primeTowerInfillGap = '0.5',
    this.primeTowerRibWall = '0.4',
    this.wipeTowerNoSparseLayers = '0',
    this.enableTowerInterfaceFeatures = '0',
    this.spiralMode = '0',
    this.draftShield = 'disabled',
    this.elefantFootCompensation = '0',
    this.xyContourCompensation = '0',
    this.xyHoleCompensation = '0',
    this.circleCompensationManualOffset = '0',
    this.enableCircleCompensation = '0',
    this.enableWrappingDetection = '0',
    this.enableArcFitting = '1',
    this.reduceCrossingWall = '0',
    this.avoidCrossingWallIncludesSupport = '0',
    this.reduceInfillRetractionMode = 'all',
    this.maxTravelDetourDistance = '0',
    this.filenameFormat =
        '{input_filename_base}_{filament_type[0]}_{print_time}.gcode',
    this.printSequence = 'by default',
    this.printExtruderId = '0',
    this.printExtruderVariant = 'default',
    this.fuzzySkin = 'none',
    this.fuzzySkinThickness = '0.3',
    this.fuzzySkinPointDistance = '0.8',
    this.fuzzySkinFirstLayer = '0',
    this.fuzzySkinNoiseType = 'classic',
    this.fuzzySkinMode = 'none',
    this.fuzzySkinScale = '1',
    this.fuzzySkinOctaves = '4',
    this.fuzzySkinPersistence = '0.5',
    this.monotonicTravelIntoWall = '0',
    this.topSurfacePattern = 'monotonic',
    this.topSurfaceDensity = '100%',
    this.bottomSurfacePattern = 'monotonic',
    this.bottomSurfaceDensity = '100%',
    this.bridgeFlow = '0.95',
    this.topSolidInfillFlowRatio = '1',
    this.ironingFlow = '10%',
  });

  Map<String, String> toMap() => {
        'seam_position': seamPosition,
        'seam_placement_away_from_overhangs': seamPlacementAwayFromOverhangs,
        'seam_slope_type': seamSlopeType,
        'seam_slope_start_height': seamSlopeStartHeight,
        'seam_slope_gap': seamSlopeGap,
        'seam_slope_min_length': seamSlopeMinLength,
        'scarf_angle_threshold': scarfAngleThreshold,
        'override_filament_scarf_seam_setting':
            overrideFilamentScarfSeamSetting,
        'wall_generator': wallGenerator,
        'wall_infill_order': wallInfillOrder,
        'z_direction_outwall_speed_continuous':
            zDirectionOutwallSpeedContinuous,
        'brim_width': brimWidth,
        'brim_object_gap': brimObjectGap,
        'brim_type': brimType,
        'skirt_distance': skirtDistance,
        'skirt_height': skirtHeight,
        'skirt_loops': skirtLoops,
        'skirt_per_object': skirtPerObject,
        'ironing_inset': ironingInset,
        'ironing_spacing': ironingSpacing,
        'ironing_speed': ironingSpeed,
        'ironing_type': ironingType,
        'enable_prime_tower': enablePrimeTower,
        'prime_tower_width': primeTowerWidth,
        'prime_tower_brim_width': primeTowerBrimWidth,
        'prime_tower_enable_framework': primeTowerEnableFramework,
        'prime_tower_lift_speed': primeTowerLiftSpeed,
        'prime_tower_lift_height': primeTowerLiftHeight,
        'prime_tower_max_speed': primeTowerMaxSpeed,
        'prime_tower_flat_ironing': primeTowerFlatIroning,
        'prime_tower_infill_gap': primeTowerInfillGap,
        'prime_tower_rib_wall': primeTowerRibWall,
        'wipe_tower_no_sparse_layers': wipeTowerNoSparseLayers,
        'enable_tower_interface_features': enableTowerInterfaceFeatures,
        'spiral_mode': spiralMode,
        'draft_shield': draftShield,
        'elefant_foot_compensation': elefantFootCompensation,
        'xy_contour_compensation': xyContourCompensation,
        'xy_hole_compensation': xyHoleCompensation,
        'circle_compensation_manual_offset': circleCompensationManualOffset,
        'enable_circle_compensation': enableCircleCompensation,
        'enable_wrapping_detection': enableWrappingDetection,
        'enable_arc_fitting': enableArcFitting,
        'reduce_crossing_wall': reduceCrossingWall,
        'avoid_crossing_wall_includes_support':
            avoidCrossingWallIncludesSupport,
        'reduce_infill_retraction_mode': reduceInfillRetractionMode,
        'max_travel_detour_distance': maxTravelDetourDistance,
        'filename_format': filenameFormat,
        'print_sequence': printSequence,
        'print_extruder_id': printExtruderId,
        'print_extruder_variant': printExtruderVariant,
        'fuzzy_skin': fuzzySkin,
        'fuzzy_skin_thickness': fuzzySkinThickness,
        'fuzzy_skin_point_distance': fuzzySkinPointDistance,
        'fuzzy_skin_first_layer': fuzzySkinFirstLayer,
        'fuzzy_skin_noise_type': fuzzySkinNoiseType,
        'fuzzy_skin_mode': fuzzySkinMode,
        'fuzzy_skin_scale': fuzzySkinScale,
        'fuzzy_skin_octaves': fuzzySkinOctaves,
        'fuzzy_skin_persistence': fuzzySkinPersistence,
        'monotonic_travel_into_wall': monotonicTravelIntoWall,
        'top_surface_pattern': topSurfacePattern,
        'top_surface_density': topSurfaceDensity,
        'bottom_surface_pattern': bottomSurfacePattern,
        'bottom_surface_density': bottomSurfaceDensity,
        'bridge_flow': bridgeFlow,
        'top_solid_infill_flow_ratio': topSolidInfillFlowRatio,
        'ironing_flow': ironingFlow,
      };

  Map<String, dynamic> toJson() => _toBambuJson(toMap());

  factory PrintOtherParams.fromMap(Map<String, dynamic> map) {
    return PrintOtherParams(
      seamPosition: _parseStr(map['seam_position']),
      seamPlacementAwayFromOverhangs:
          _parseStr(map['seam_placement_away_from_overhangs']),
      seamSlopeType: _parseStr(map['seam_slope_type']),
      seamSlopeStartHeight: _parseStr(map['seam_slope_start_height']),
      seamSlopeGap: _parseStr(map['seam_slope_gap']),
      seamSlopeMinLength: _parseStr(map['seam_slope_min_length']),
      scarfAngleThreshold: _parseStr(map['scarf_angle_threshold']),
      overrideFilamentScarfSeamSetting:
          _parseStr(map['override_filament_scarf_seam_setting']),
      wallGenerator: _parseStr(map['wall_generator']),
      wallInfillOrder: _parseStr(map['wall_infill_order']),
      zDirectionOutwallSpeedContinuous:
          _parseStr(map['z_direction_outwall_speed_continuous']),
      brimWidth: _parseStr(map['brim_width']),
      brimObjectGap: _parseStr(map['brim_object_gap']),
      brimType: _parseStr(map['brim_type']),
      skirtDistance: _parseStr(map['skirt_distance']),
      skirtHeight: _parseStr(map['skirt_height']),
      skirtLoops: _parseStr(map['skirt_loops']),
      skirtPerObject: _parseStr(map['skirt_per_object']),
      ironingInset: _parseStr(map['ironing_inset']),
      ironingSpacing: _parseStr(map['ironing_spacing']),
      ironingSpeed: _parseStr(map['ironing_speed']),
      ironingType: _parseStr(map['ironing_type']),
      enablePrimeTower: _parseStr(map['enable_prime_tower']),
      primeTowerWidth: _parseStr(map['prime_tower_width']),
      primeTowerBrimWidth: _parseStr(map['prime_tower_brim_width']),
      primeTowerEnableFramework: _parseStr(map['prime_tower_enable_framework']),
      primeTowerLiftSpeed: _parseStr(map['prime_tower_lift_speed']),
      primeTowerLiftHeight: _parseStr(map['prime_tower_lift_height']),
      primeTowerMaxSpeed: _parseStr(map['prime_tower_max_speed']),
      primeTowerFlatIroning: _parseStr(map['prime_tower_flat_ironing']),
      primeTowerInfillGap: _parseStr(map['prime_tower_infill_gap']),
      primeTowerRibWall: _parseStr(map['prime_tower_rib_wall']),
      wipeTowerNoSparseLayers: _parseStr(map['wipe_tower_no_sparse_layers']),
      enableTowerInterfaceFeatures:
          _parseStr(map['enable_tower_interface_features']),
      spiralMode: _parseStr(map['spiral_mode']),
      draftShield: _parseStr(map['draft_shield']),
      elefantFootCompensation: _parseStr(map['elefant_foot_compensation']),
      xyContourCompensation: _parseStr(map['xy_contour_compensation']),
      xyHoleCompensation: _parseStr(map['xy_hole_compensation']),
      circleCompensationManualOffset:
          _parseStr(map['circle_compensation_manual_offset']),
      enableCircleCompensation: _parseStr(map['enable_circle_compensation']),
      enableWrappingDetection: _parseStr(map['enable_wrapping_detection']),
      enableArcFitting: _parseStr(map['enable_arc_fitting']),
      reduceCrossingWall: _parseStr(map['reduce_crossing_wall']),
      avoidCrossingWallIncludesSupport:
          _parseStr(map['avoid_crossing_wall_includes_support']),
      reduceInfillRetractionMode:
          _parseStr(map['reduce_infill_retraction_mode']),
      maxTravelDetourDistance: _parseStr(map['max_travel_detour_distance']),
      filenameFormat: _parseStr(map['filename_format']),
      printSequence: _parseStr(map['print_sequence']),
      printExtruderId: _parseStr(map['print_extruder_id']),
      printExtruderVariant: _parseStr(map['print_extruder_variant']),
      fuzzySkin: _parseStr(map['fuzzy_skin']),
      fuzzySkinThickness: _parseStr(map['fuzzy_skin_thickness']),
      fuzzySkinPointDistance: _parseStr(map['fuzzy_skin_point_distance']),
      fuzzySkinFirstLayer: _parseStr(map['fuzzy_skin_first_layer']),
      fuzzySkinNoiseType: _parseStr(map['fuzzy_skin_noise_type']),
      fuzzySkinMode: _parseStr(map['fuzzy_skin_mode']),
      fuzzySkinScale: _parseStr(map['fuzzy_skin_scale']),
      fuzzySkinOctaves: _parseStr(map['fuzzy_skin_octaves']),
      fuzzySkinPersistence: _parseStr(map['fuzzy_skin_persistence']),
      monotonicTravelIntoWall: _parseStr(map['monotonic_travel_into_wall']),
      topSurfacePattern: _parseStr(map['top_surface_pattern']),
      topSurfaceDensity: _parseStr(map['top_surface_density']),
      bottomSurfacePattern: _parseStr(map['bottom_surface_pattern']),
      bottomSurfaceDensity: _parseStr(map['bottom_surface_density']),
      bridgeFlow: _parseStr(map['bridge_flow']),
      topSolidInfillFlowRatio: _parseStr(map['top_solid_infill_flow_ratio']),
      ironingFlow: _parseStr(map['ironing_flow']),
    );
  }
}
