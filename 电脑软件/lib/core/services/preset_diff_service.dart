import '../../data/models/print_parameter.dart';

class PresetParameterDiff {
  final String field;
  final String valueA;
  final String valueB;

  const PresetParameterDiff({
    required this.field,
    required this.valueA,
    required this.valueB,
  });
}

/// 参数比较的唯一事实来源，供比较弹窗和参数实验共同使用。
class PresetDiffService {
  PresetDiffService._();

  static Map<String, String> flatten(PrintParameterPreset preset) => {
        'material': preset.material ?? '',
        'scene': preset.scene ?? '',
        'plate_type': preset.plateType ?? '',
        'compatible_printers': preset.compatiblePrinters.join(';'),
        ...preset.quality.toMap(),
        ...preset.strength.toMap(),
        ...preset.speed.toMap(),
        ...preset.support.toMap(),
        ...preset.other.toMap(),
      };

  static List<PresetParameterDiff> comparePresets(
    PrintParameterPreset a,
    PrintParameterPreset b,
  ) {
    return compareMaps(flatten(a), flatten(b));
  }

  static List<PresetParameterDiff> compareMaps(
    Map<String, String> a,
    Map<String, String> b,
  ) {
    final keys = <String>{...a.keys, ...b.keys}.toList()..sort();
    return [
      for (final key in keys)
        if (!_valuesEqual(a[key] ?? '', b[key] ?? ''))
          PresetParameterDiff(
            field: key,
            valueA: a[key] ?? '',
            valueB: b[key] ?? '',
          ),
    ];
  }

  static String summarize(List<PresetParameterDiff> diffs) {
    if (diffs.isEmpty) return '无参数差异';
    final preview = diffs
        .take(8)
        .map((diff) => '${diff.field}: ${diff.valueA} -> ${diff.valueB}')
        .join('\n');
    return diffs.length > 8 ? '$preview\n另有 ${diffs.length - 8} 项差异' : preview;
  }

  static bool _valuesEqual(String a, String b) {
    final aNum = double.tryParse(a.replaceAll('%', '').trim());
    final bNum = double.tryParse(b.replaceAll('%', '').trim());
    if (aNum != null && bNum != null) {
      return (aNum - bNum).abs() < 0.0001;
    }
    return a.trim() == b.trim();
  }
}
