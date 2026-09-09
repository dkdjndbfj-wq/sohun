import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/data/external/print_task/print_task_state_machine.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// PrintTaskStateMachine 单元测试。
///
/// 覆盖：
/// - translate：BambuGcodeState → PrintTaskStatus 映射
/// - canTransition：状态转换合法性校验
/// - safeTransition：非法转换回退原状态
///
/// 状态机错了会导致任务状态错乱（如 finished 后又被改成 printing），
/// 进而触发错误的耗材结算。
void main() {
  group('PrintTaskStateMachine.translate - G-code 状态映射', () {
    test('running → printing', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.planned,
          gcodeState: BambuGcodeState.running,
        ),
        PrintTaskStatus.printing,
      );
    });

    test('pause → paused', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.pause,
        ),
        PrintTaskStatus.paused,
      );
    });

    test('finish → finished', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.finish,
        ),
        PrintTaskStatus.finished,
      );
    });

    test('failed → failed', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.failed,
        ),
        PrintTaskStatus.failed,
      );
    });

    test('idle + current=planned → 保持 planned（任务未真正开始）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.planned,
          gcodeState: BambuGcodeState.idle,
        ),
        PrintTaskStatus.planned,
      );
    });

    test('idle + current=printing → cancelled（运行中突然空闲=异常终止）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.idle,
        ),
        PrintTaskStatus.cancelled,
      );
    });

    test('idle + current=paused → cancelled（暂停中突然空闲=异常终止）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.paused,
          gcodeState: BambuGcodeState.idle,
        ),
        PrintTaskStatus.cancelled,
      );
    });

    test('idle + current=finished → 保持 finished（终态不变）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.finished,
          gcodeState: BambuGcodeState.idle,
        ),
        PrintTaskStatus.finished,
      );
    });

    test('idle + current=cancelled → 保持 cancelled（终态不变）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.cancelled,
          gcodeState: BambuGcodeState.idle,
        ),
        PrintTaskStatus.cancelled,
      );
    });

    test('init → 保持当前（过渡态）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.init,
        ),
        PrintTaskStatus.printing,
      );
    });

    test('prepare → 保持当前（过渡态）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.prepare,
        ),
        PrintTaskStatus.printing,
      );
    });

    test('offline → 保持当前（断网，等重连）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.offline,
        ),
        PrintTaskStatus.printing,
      );
    });

    test('slicing → 保持当前（切片中，不影响任务）', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.slicing,
        ),
        PrintTaskStatus.printing,
      );
    });

    test('unknown → 保持当前', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.unknown,
        ),
        PrintTaskStatus.printing,
      );
    });
  });

  group('PrintTaskStateMachine.canTransition - 合法转换', () {
    test('同状态转换：允许', () {
      for (final s in PrintTaskStatus.values) {
        expect(
          PrintTaskStateMachine.canTransition(from: s, to: s),
          true,
          reason: '$s → $s 应允许',
        );
      }
    });

    test('planned → printing：允许', () {
      expect(
        PrintTaskStateMachine.canTransition(
          from: PrintTaskStatus.planned,
          to: PrintTaskStatus.printing,
        ),
        true,
      );
    });

    test('planned → cancelled：允许（取消未开始的任务）', () {
      expect(
        PrintTaskStateMachine.canTransition(
          from: PrintTaskStatus.planned,
          to: PrintTaskStatus.cancelled,
        ),
        true,
      );
    });

    test('printing → paused/finished/cancelled/failed：均允许', () {
      for (final to in [
        PrintTaskStatus.paused,
        PrintTaskStatus.finished,
        PrintTaskStatus.cancelled,
        PrintTaskStatus.failed,
      ]) {
        expect(
          PrintTaskStateMachine.canTransition(
            from: PrintTaskStatus.printing,
            to: to,
          ),
          true,
          reason: 'printing → $to 应允许',
        );
      }
    });

    test('paused → printing/cancelled/failed：均允许', () {
      for (final to in [
        PrintTaskStatus.printing,
        PrintTaskStatus.cancelled,
        PrintTaskStatus.failed,
      ]) {
        expect(
          PrintTaskStateMachine.canTransition(
            from: PrintTaskStatus.paused,
            to: to,
          ),
          true,
          reason: 'paused → $to 应允许',
        );
      }
    });

    test('paused → finished：不允许（暂停状态不能直接完成）', () {
      expect(
        PrintTaskStateMachine.canTransition(
          from: PrintTaskStatus.paused,
          to: PrintTaskStatus.finished,
        ),
        false,
      );
    });
  });

  group('PrintTaskStateMachine.canTransition - 非法转换', () {
    test('终态 → 非终态：不允许（除 planned 外）', () {
      for (final terminal in [
        PrintTaskStatus.finished,
        PrintTaskStatus.cancelled,
        PrintTaskStatus.failed,
      ]) {
        for (final to in [
          PrintTaskStatus.printing,
          PrintTaskStatus.paused,
        ]) {
          expect(
            PrintTaskStateMachine.canTransition(from: terminal, to: to),
            false,
            reason: '$terminal → $to 应不允许',
          );
        }
      }
    });

    test('终态 → planned：允许（显式重新规划）', () {
      for (final terminal in [
        PrintTaskStatus.finished,
        PrintTaskStatus.cancelled,
        PrintTaskStatus.failed,
      ]) {
        expect(
          PrintTaskStateMachine.canTransition(
            from: terminal,
            to: PrintTaskStatus.planned,
          ),
          true,
          reason: '$terminal → planned 应允许（重新规划）',
        );
      }
    });

    test('planned → finished/failed/paused：不允许（必须先 printing）', () {
      for (final to in [
        PrintTaskStatus.finished,
        PrintTaskStatus.failed,
        PrintTaskStatus.paused,
      ]) {
        expect(
          PrintTaskStateMachine.canTransition(
            from: PrintTaskStatus.planned,
            to: to,
          ),
          false,
          reason: 'planned → $to 应不允许',
        );
      }
    });
  });

  group('PrintTaskStateMachine.safeTransition - 安全转换', () {
    test('合法转换：返回新状态', () {
      expect(
        PrintTaskStateMachine.safeTransition(
          from: PrintTaskStatus.printing,
          to: PrintTaskStatus.paused,
        ),
        PrintTaskStatus.paused,
      );
    });

    test('非法转换：返回原状态（防御性）', () {
      expect(
        PrintTaskStateMachine.safeTransition(
          from: PrintTaskStatus.finished,
          to: PrintTaskStatus.printing,
        ),
        PrintTaskStatus.finished,
      );
    });

    test('同状态：返回同状态', () {
      expect(
        PrintTaskStateMachine.safeTransition(
          from: PrintTaskStatus.printing,
          to: PrintTaskStatus.printing,
        ),
        PrintTaskStatus.printing,
      );
    });
  });
}
