import '../../database/daos/print_task_dao.dart';
import '../printer/bambu_printer_models.dart';

/// 打印任务状态机。
///
/// 负责把打印机上报的 [BambuGcodeState] 翻译成数据库里的 [PrintTaskStatus]，
/// 并校验状态转换的合法性（防止非法跳转，例如 finished → printing）。
///
/// 状态对应关系（对齐拓竹真实 MQTT 协议，实际上报为大写字段值，
/// BambuGcodeState.fromCode 已做大小写归一化）：
/// ```
/// BambuGcodeState         →  PrintTaskStatus
/// ─────────────────────────────────────────────
/// idle (任务未开始)        →  planned
/// idle (任务运行中突然空闲) →  cancelled（异常终止）
/// running                  →  printing
/// pause                    →  paused
/// finish                   →  finished
/// failed                   →  failed
/// init / prepare           →  保持当前（过渡态，等打印机稳定）
/// offline                  →  保持当前（断网，等重连）
/// slicing                  →  保持当前（切片中，不影响打印任务）
/// unknown                  →  保持当前
/// ```
class PrintTaskStateMachine {
  PrintTaskStateMachine._();

  /// 把打印机状态映射为打印任务状态。
  ///
  /// [current] 当前任务状态（用于区分 idle 是"未开始"还是"被取消"）
  /// [gcodeState] 打印机上报的 G-code 状态
  /// [lastMcPercent] / [lastLayer] / [totalLayers] 最后已知进度，用于判断
  ///   idle 到底是"异常终止"还是"软件离线期间正常打完"。
  static PrintTaskStatus translate({
    required PrintTaskStatus current,
    required BambuGcodeState gcodeState,
    int lastMcPercent = 0,
    int lastLayer = 0,
    int totalLayers = 0,
  }) {
    switch (gcodeState) {
      case BambuGcodeState.idle:
        // idle 在不同上下文含义不同：
        // - current == planned：任务还没真正开始 → 保持 planned
        // - current == printing/paused：任务运行中突然变 idle
        // - current == finished/cancelled/failed：终态保持
        if (current == PrintTaskStatus.planned || current.isTerminal) {
          return current;
        }
        // 关键修复：软件在打印中被关闭、打印机自行完成后回到 idle。
        // 重启后收到 idle 若一律判 cancelled，会导致按旧进度结算 → 漏扣、历史失真。
        // 进度接近完成（>=95% 或已达最后一层）时判为 finished 而非 cancelled。
        if (lastMcPercent >= 95 ||
            (totalLayers > 0 && lastLayer >= totalLayers)) {
          return PrintTaskStatus.finished;
        }
        return PrintTaskStatus.cancelled;

      case BambuGcodeState.running:
        return PrintTaskStatus.printing;

      case BambuGcodeState.pause:
        return PrintTaskStatus.paused;

      case BambuGcodeState.finish:
        return PrintTaskStatus.finished;

      case BambuGcodeState.failed:
        return PrintTaskStatus.failed;

      // 过渡态：打印机正在切换状态，保持当前任务状态不变
      case BambuGcodeState.init:
      case BambuGcodeState.prepare:
      // 非任务相关态：保持当前
      case BambuGcodeState.offline:
      case BambuGcodeState.slicing:
      case BambuGcodeState.unknown:
        return current;
    }
  }

  /// 校验状态转换是否合法。
  /// 返回 true 表示允许从 [from] 转到 [to]。
  static bool canTransition({
    required PrintTaskStatus from,
    required PrintTaskStatus to,
  }) {
    // 同状态：允许（无操作）
    if (from == to) return true;

    // 终态不允许再变（除非显式重新规划）
    if (from.isTerminal) {
      return to == PrintTaskStatus.planned;
    }

    // 非终态之间的合法转换：
    // - planned → printing（开始打印）
    // - planned → cancelled（用户取消未开始的任务）
    // - printing → paused（暂停）
    // - printing → finished（完成）
    // - printing → cancelled（用户停止）
    // - printing → failed（机器报错）
    // - paused → printing（恢复）
    // - paused → cancelled（用户停止）
    // - paused → failed（机器报错）
    switch (from) {
      case PrintTaskStatus.planned:
        return to == PrintTaskStatus.printing ||
            to == PrintTaskStatus.cancelled;

      case PrintTaskStatus.printing:
        return to == PrintTaskStatus.paused ||
            to == PrintTaskStatus.finished ||
            to == PrintTaskStatus.cancelled ||
            to == PrintTaskStatus.failed;

      case PrintTaskStatus.paused:
        return to == PrintTaskStatus.printing ||
            to == PrintTaskStatus.cancelled ||
            to == PrintTaskStatus.failed;

      case PrintTaskStatus.finished:
      case PrintTaskStatus.cancelled:
      case PrintTaskStatus.failed:
        return to == PrintTaskStatus.planned;
    }
  }

  /// 安全转换：若合法返回新状态，否则返回原状态。
  static PrintTaskStatus safeTransition({
    required PrintTaskStatus from,
    required PrintTaskStatus to,
  }) {
    return canTransition(from: from, to: to) ? to : from;
  }
}
