import 'dart:convert';

import 'package:consumable_tracker_desktop/data/external/community/studio_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('listVideoDemand reads active order viewers', () async {
    final client = StudioApiClient(
      baseUri: Uri.parse('https://api.sohun.test/'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/studio/workspaces/farm-1/video-demand',
        );
        expect(request.headers['Authorization'], 'Bearer access-token');
        return http.Response(
          jsonEncode({
            'items': [
              {
                'orderId': 'order-1',
                'workOrderId': 'work-1',
                'viewerCount': 2,
                'expiresAt': '2026-08-04T12:00:18.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final demand = await client.listVideoDemand(
      accessToken: 'access-token',
      workspaceId: 'farm-1',
    );

    expect(demand, hasLength(1));
    expect(demand.single.orderId, 'order-1');
    expect(demand.single.workOrderId, 'work-1');
    expect(demand.single.viewerCount, 2);
    expect(
      demand.single.expiresAt,
      DateTime.parse('2026-08-04T12:00:18.000Z'),
    );
  });

  test('createVideoSession accepts a signed RTMP push URL', () async {
    final client = StudioApiClient(
      baseUri: Uri.parse('https://api.sohun.test/'),
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/v1/studio/workspaces/farm-1/video-sessions',
        );
        return http.Response(
          jsonEncode({
            'id': 'session-1',
            'transport': 'rtmp',
            'pushUrl':
                'rtmp://push.sohun.top/live/stream-1?txSecret=abc&txTime=123',
            'expiresAt': '2026-08-04T14:00:00.000Z',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final session = await client.createVideoSession(
      accessToken: 'access-token',
      workspaceId: 'farm-1',
      orderId: 'order-1',
      workOrderId: 'work-1',
      publicPrinterName: '打印机 1',
    );

    expect(session.usesRtmp, isTrue);
    expect(session.transport, 'rtmp');
    expect(session.pushUri?.host, 'push.sohun.top');
    expect(session.uploadUri, isNull);
    expect(session.uploadToken, isNull);
  });

  test('getSnapshot keeps server-side share link metadata', () async {
    final client = StudioApiClient(
      baseUri: Uri.parse('https://api.sohun.test/'),
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'revision': 3,
              'snapshot': {'schemaVersion': 2},
              'members': const [],
              'shareLinks': [
                {
                  'id': 'share-1',
                  'orderId': 'order-1',
                  'tokenPreview': 'abcd…wxyz',
                  'relativeUrl': '/studio/share/share-1',
                  'active': true,
                  'passwordRequired': true,
                  'createdAt': '2026-08-05T01:00:00.000Z',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    final remote = await client.getSnapshot(
      accessToken: 'access-token',
      workspaceId: 'farm-1',
    );
    expect(remote.revision, 3);
    expect(remote.shareLinks.single['id'], 'share-1');
    expect(
      remote.shareLinks.single['publicUrl'],
      'https://api.sohun.test/studio/share/share-1',
    );
  });

  test('getFarmAuditLogs reads actor snapshots and operation summaries',
      () async {
    final client = StudioApiClient(
      baseUri: Uri.parse('https://api.sohun.test/'),
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/v1/farm/organizations/farm-1/audit-logs',
        );
        expect(request.url.queryParameters['limit'], '500');
        expect(request.url.queryParameters['offset'], '0');
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'server-audit-1',
                'clientEventId': 'client-audit-1',
                'action': 'member.removed',
                'actorName': '管理员王五',
                'actorIdentity': 'administrator',
                'actorMemberId': 'owner-1',
                'resourceType': 'member',
                'resourceId': 'member-1',
                'result': 'success',
                'summary': '删除成员张三（历史操作记录已保留）',
                'createdAt': '2026-08-05T06:30:00.000Z',
              },
            ],
            'hasMore': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final logs = await client.getFarmAuditLogs(
      accessToken: 'access-token',
      organizationId: 'farm-1',
    );

    expect(logs, hasLength(1));
    expect(logs.single.clientEventId, 'client-audit-1');
    expect(logs.single.actorName, '管理员王五');
    expect(logs.single.action, 'member.removed');
    expect(logs.single.summary, contains('历史操作记录已保留'));
  });
}
