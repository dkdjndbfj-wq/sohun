import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_client.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// BambuCloudException + BambuGcodeState 单元测试。
///
/// 覆盖：
/// - BambuCloudException.isRetryable：判断错误是否可重试（P1-6 核心逻辑）
/// - BambuCloudException 默认值与构造
/// - BambuGcodeState.fromCode：MQTT 大小写归一化（打印机状态解析）
/// - BambuGcodeState 状态谓词（isConsuming/canPause/canResume/canStop/isTerminal）
///
/// 这些是云 API 兼容层和 MQTT 状态解析的基础，错了会导致：
/// - isRetryable 错 → 不该重试的重试（如 401 重复登录被风控）/ 该重试的不重试（网络抖动直接失败）
/// - fromCode 错 → 打印机状态识别错误，任务状态机推进异常
void main() {
  group('BambuCloudException.isRetryable - 错误分类', () {
    test('network 错误：可重试', () {
      const e = BambuCloudException(
        '网络错误',
        category: BambuCloudErrorCategory.network,
      );
      expect(e.isRetryable, true);
    });

    test('server 错误（5xx）：可重试', () {
      const e = BambuCloudException(
        '服务器错误',
        category: BambuCloudErrorCategory.server,
        statusCode: 500,
      );
      expect(e.isRetryable, true);
    });

    test('rateLimit 错误（429）：可重试', () {
      const e = BambuCloudException(
        '请求过频',
        category: BambuCloudErrorCategory.rateLimit,
        statusCode: 429,
      );
      expect(e.isRetryable, true);
    });

    test('authentication 错误（401）：不可重试', () {
      const e = BambuCloudException(
        '账号或密码错误',
        category: BambuCloudErrorCategory.authentication,
        statusCode: 401,
      );
      expect(e.isRetryable, false);
    });

    test('permission 错误（403）：不可重试', () {
      const e = BambuCloudException(
        'Cloudflare 拦截',
        category: BambuCloudErrorCategory.permission,
        statusCode: 403,
      );
      expect(e.isRetryable, false);
    });

    test('protocol 错误（404）：不可重试', () {
      const e = BambuCloudException(
        '接口不存在',
        category: BambuCloudErrorCategory.protocol,
        statusCode: 404,
      );
      expect(e.isRetryable, false);
    });

    test('client 错误（400）：不可重试', () {
      const e = BambuCloudException(
        '参数错误',
        category: BambuCloudErrorCategory.client,
        statusCode: 400,
      );
      expect(e.isRetryable, false);
    });

    test('unknown 错误（默认）：不可重试', () {
      const e = BambuCloudException('未知错误');
      expect(e.isRetryable, false);
      expect(e.category, BambuCloudErrorCategory.unknown);
      expect(e.statusCode, isNull);
    });
  });

  group('BambuCloudException - toString', () {
    test('toString 含 BambuCloudException 前缀', () {
      const e = BambuCloudException('测试错误');
      expect(e.toString(), 'BambuCloudException: 测试错误');
    });
  });

  group('BambuGcodeState.fromCode - 大小写归一化', () {
    test('小写 code：直接匹配', () {
      expect(BambuGcodeState.fromCode('running'), BambuGcodeState.running);
      expect(BambuGcodeState.fromCode('pause'), BambuGcodeState.pause);
      expect(BambuGcodeState.fromCode('idle'), BambuGcodeState.idle);
      expect(BambuGcodeState.fromCode('finish'), BambuGcodeState.finish);
      expect(BambuGcodeState.fromCode('failed'), BambuGcodeState.failed);
    });

    test('大写 code：归一化为小写后匹配（拓竹 MQTT 实际上报大写）', () {
      expect(BambuGcodeState.fromCode('RUNNING'), BambuGcodeState.running);
      expect(BambuGcodeState.fromCode('PAUSE'), BambuGcodeState.pause);
      expect(BambuGcodeState.fromCode('IDLE'), BambuGcodeState.idle);
      expect(BambuGcodeState.fromCode('FINISH'), BambuGcodeState.finish);
      expect(BambuGcodeState.fromCode('FAILED'), BambuGcodeState.failed);
      expect(BambuGcodeState.fromCode('INIT'), BambuGcodeState.init);
      expect(BambuGcodeState.fromCode('PREPARE'), BambuGcodeState.prepare);
      expect(BambuGcodeState.fromCode('OFFLINE'), BambuGcodeState.offline);
      expect(BambuGcodeState.fromCode('SLICING'), BambuGcodeState.slicing);
    });

    test('混合大小写：归一化匹配', () {
      expect(BambuGcodeState.fromCode('Running'), BambuGcodeState.running);
      expect(BambuGcodeState.fromCode('PaUsE'), BambuGcodeState.pause);
    });

    test('空字符串：返回 unknown', () {
      expect(BambuGcodeState.fromCode(''), BambuGcodeState.unknown);
    });

    test('未知 code：返回 unknown', () {
      expect(BambuGcodeState.fromCode('invalid'), BambuGcodeState.unknown);
      expect(
        BambuGcodeState.fromCode('UNKNOWN_STATE'),
        BambuGcodeState.unknown,
      );
    });
  });

  group('BambuGcodeState - 状态谓词', () {
    test('isConsuming：仅 running 为 true', () {
      expect(BambuGcodeState.running.isConsuming, true);
      expect(BambuGcodeState.pause.isConsuming, false);
      expect(BambuGcodeState.idle.isConsuming, false);
      expect(BambuGcodeState.finish.isConsuming, false);
    });

    test('canPause：仅 running 为 true', () {
      expect(BambuGcodeState.running.canPause, true);
      expect(BambuGcodeState.pause.canPause, false);
      expect(BambuGcodeState.idle.canPause, false);
    });

    test('canResume：仅 pause 为 true', () {
      expect(BambuGcodeState.pause.canResume, true);
      expect(BambuGcodeState.running.canResume, false);
      expect(BambuGcodeState.idle.canResume, false);
    });

    test('canStop：running/pause/init/prepare 为 true', () {
      expect(BambuGcodeState.running.canStop, true);
      expect(BambuGcodeState.pause.canStop, true);
      expect(BambuGcodeState.init.canStop, true);
      expect(BambuGcodeState.prepare.canStop, true);
      expect(BambuGcodeState.idle.canStop, false);
      expect(BambuGcodeState.finish.canStop, false);
      expect(BambuGcodeState.failed.canStop, false);
    });

    test('isTerminal：仅 finish/failed 为 true', () {
      expect(BambuGcodeState.finish.isTerminal, true);
      expect(BambuGcodeState.failed.isTerminal, true);
      expect(BambuGcodeState.running.isTerminal, false);
      expect(BambuGcodeState.pause.isTerminal, false);
      expect(BambuGcodeState.idle.isTerminal, false);
    });

    test('isTransient：仅 init/prepare 为 true', () {
      expect(BambuGcodeState.init.isTransient, true);
      expect(BambuGcodeState.prepare.isTransient, true);
      expect(BambuGcodeState.running.isTransient, false);
      expect(BambuGcodeState.pause.isTransient, false);
      expect(BambuGcodeState.idle.isTransient, false);
    });
  });
}
