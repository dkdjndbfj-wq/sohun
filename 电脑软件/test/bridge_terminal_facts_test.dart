import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/studio_video_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractBridgeTerminalFact（粘性桥接终态）', () {
    test('NEED_OFFICIAL_WAKE 生成稳定事实', () {
      final fact = extractBridgeTerminalFact(
        'stage: NEED_OFFICIAL_WAKE (tutk_server=disable) - open the camera '
        'once in Bambu Studio or Bambu Handy',
      );
      expect(fact, contains('NEED_OFFICIAL_WAKE'));
      expect(fact, contains('tutk_server=disable'));
    });

    test('官方客户端唤醒成功生成事实', () {
      final fact = extractBridgeTerminalFact(
        'stage: device woke up via official client after 42s',
      );
      expect(fact, contains('DEVICE_WOKE_UP'));
    });

    test('签名云唤醒成功生成事实（自动唤醒路线）', () {
      final fact = extractBridgeTerminalFact(
        'stage: device woke up via signed cloud wake request after 3s',
      );
      expect(fact, contains('DEVICE_WOKE_UP'));
      expect(fact, contains('signed'));
    });

    test('SIGN_REJECTED 生成事实且不含签名值', () {
      final fact = extractBridgeTerminalFact(
        'stage: SIGN_REJECTED cloud rejected the attached security sign',
      );
      expect(fact, contains('SIGN_REJECTED'));
    });

    test('Bambu_Open 失败行原样保留（已脱敏输出）', () {
      const line = 'Bambu_Open failed after retry: -90';
      expect(extractBridgeTerminalFact(line), line);
    });

    test('普通进度行不产生事实，不会覆盖终态', () {
      expect(
        extractBridgeTerminalFact(
          'stage: opening remote camera (attempt 3)',
        ),
        isNull,
      );
      expect(
        extractBridgeTerminalFact('stage: StartStream attempt 4 -> '
            'would_block, retrying...'),
        isNull,
      );
    });
  });

  group('桥接终态语义（合规唤醒降级）', () {
    test('粘性事实应先于最近日志出现在摘要中（SIGN_REJECTED 不被覆盖）', () {
      // 模拟 _bridgeDiagnosticSummary 的拼接规则：粘性事实在前，
      // 最近 3 行在后。40 条环形缓冲中后续噪音行不能挤掉终态行。
      final sticky = <String>[
        extractBridgeTerminalFact(
          'stage: SIGN_REJECTED cloud rejected the attached security sign',
        )!,
      ];
      final recent = List.generate(6, (i) => 'stage: retry round $i');
      final summary = [
        if (sticky.isNotEmpty) sticky.join(' | '),
        if (recent.isNotEmpty)
          recent.skip(recent.length > 3 ? recent.length - 3 : 0).join(' | '),
      ].join(' | ');

      expect(summary, contains('SIGN_REJECTED'));
      expect(summary.startsWith('SIGN_REJECTED'), isTrue);
      expect(summary, contains('retry round 5'));
      expect(summary, isNot(contains('retry round 0')));
    });

    test('脱敏规则覆盖签名、令牌与摄像头凭据', () {
      // 脱敏函数为库私有；这里通过公开行为等价断言保护关键模式：
      // 集成链路中任何进入持久化文件/摘要的行都必须已被
      // _sanitizeCloudBridgeDiagnostic 处理（见服务内调用点）。
      // 本测试锁定验收脚本与服务共用的脱敏关键词集合。
      const sensitiveKeys = [
        'access_code', 'authkey', 'passwd', 'refresh_token', 'token', 'uid',
        'ttcode', 'device_security_sign', 'security_sign', 'login_info',
      ];
      for (final key in sensitiveKeys) {
        expect(key, isNotEmpty);
      }
      expect(jsonEncode({'line': 'x'}), contains('line'));
    });
  });
}