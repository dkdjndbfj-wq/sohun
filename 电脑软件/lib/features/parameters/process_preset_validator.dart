import '../../data/models/print_parameter.dart';
import 'parameter_field_defs.dart';

class ProcessPresetValidationIssue {
  const ProcessPresetValidationIssue({
    required this.key,
    required this.value,
    required this.reason,
  });

  final String key;
  final String value;
  final String reason;
}

/// Enforces the same process-parameter ranges used by the editor before a
/// preset crosses an import or slicer-application boundary.
class ProcessPresetValidator {
  ProcessPresetValidator._();

  static List<ProcessPresetValidationIssue> validate(
    PrintParameterPreset preset,
  ) {
    final values = <String, String>{
      ...preset.quality.toMap(),
      ...preset.strength.toMap(),
      ...preset.speed.toMap(),
      ...preset.support.toMap(),
      ...preset.other.toMap(),
    };
    final issues = <ProcessPresetValidationIssue>[];
    final checkedKeys = <String>{};
    for (final field in allProcessFields) {
      if (!checkedKeys.add(field.key)) continue;
      final rawValue = values[field.key]?.trim();
      if (rawValue == null || rawValue.isEmpty) continue;

      if (field.isSwitch) {
        if (rawValue != '0' && rawValue != '1') {
          issues.add(
            ProcessPresetValidationIssue(
              key: field.key,
              value: rawValue,
              reason: 'must be 0 or 1',
            ),
          );
        }
        continue;
      }
      if (!field.isNumeric || field.options != null) continue;

      final numericText = rawValue.endsWith('%')
          ? rawValue.substring(0, rawValue.length - 1).trim()
          : rawValue;
      final value = double.tryParse(numericText);
      if (value == null || !value.isFinite) {
        issues.add(
          ProcessPresetValidationIssue(
            key: field.key,
            value: rawValue,
            reason: 'must be a finite number',
          ),
        );
        continue;
      }
      final min = field.effectiveMin;
      final max = field.effectiveMax;
      if ((min != null && value < min) || (max != null && value > max)) {
        issues.add(
          ProcessPresetValidationIssue(
            key: field.key,
            value: rawValue,
            reason: 'must be between $min and $max',
          ),
        );
      }
    }
    return issues;
  }

  static void validateOrThrow(PrintParameterPreset preset) {
    final issues = validate(preset);
    if (issues.isEmpty) return;
    final first = issues.first;
    throw FormatException(
      'Invalid process parameter ${first.key}=${first.value}: ${first.reason}',
    );
  }
}
