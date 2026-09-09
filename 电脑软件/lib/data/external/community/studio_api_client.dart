import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class StudioCloudException implements Exception {
  const StudioCloudException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  bool get isConflict => statusCode == 409;

  @override
  String toString() => message;
}

class StudioRemoteSnapshot {
  const StudioRemoteSnapshot({
    required this.revision,
    required this.snapshot,
    required this.members,
    required this.shareLinks,
  });

  final int revision;
  final Map<String, dynamic> snapshot;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> shareLinks;
}

class StudioRemoteShareLink {
  const StudioRemoteShareLink({
    required this.id,
    required this.tokenPreview,
    required this.publicUrl,
    required this.expiresAt,
  });

  final String id;
  final String tokenPreview;
  final Uri publicUrl;
  final DateTime expiresAt;
}

class StudioRemoteAuditLog {
  const StudioRemoteAuditLog({
    required this.id,
    required this.action,
    required this.result,
    required this.createdAt,
    this.clientEventId,
    this.actorName,
    this.actorIdentity,
    this.actorMemberId,
    this.resourceType,
    this.resourceId,
    this.summary,
  });

  final String id;
  final String? clientEventId;
  final String action;
  final String result;
  final DateTime createdAt;
  final String? actorName;
  final String? actorIdentity;
  final String? actorMemberId;
  final String? resourceType;
  final String? resourceId;
  final String? summary;
}

class StudioVideoUplinkSession {
  const StudioVideoUplinkSession({
    required this.id,
    required this.transport,
    required this.expiresAt,
    this.uploadToken,
    this.uploadUri,
    this.pushUri,
  });

  final String id;
  final String transport;
  final String? uploadToken;
  final Uri? uploadUri;
  final Uri? pushUri;
  final DateTime expiresAt;

  bool get usesRtmp => transport == 'rtmp' && pushUri != null;
}

class StudioVideoDemand {
  const StudioVideoDemand({
    required this.orderId,
    required this.workOrderId,
    required this.viewerCount,
    required this.expiresAt,
  });

  final String orderId;
  final String workOrderId;
  final int viewerCount;
  final DateTime expiresAt;
}

class StudioApiClient {
  StudioApiClient({required Uri baseUri, required http.Client httpClient})
      : baseUri = _normalize(baseUri),
        _httpClient = httpClient;

  final Uri baseUri;
  final http.Client _httpClient;

  Future<List<Map<String, dynamic>>> listWorkspaces(String accessToken) async {
    final json = await _request('GET', '/v1/studio/workspaces', accessToken);
    return _objectList(json['items']);
  }

  Future<void> createWorkspace({
    required String accessToken,
    required String id,
    required String name,
  }) async {
    await _request(
      'POST',
      '/v1/studio/workspaces',
      accessToken,
      body: {'id': id, 'name': name},
    );
  }

  Future<StudioRemoteSnapshot> getSnapshot({
    required String accessToken,
    required String workspaceId,
  }) async {
    final json = await _request(
      'GET',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/snapshot',
      accessToken,
    );
    final shareLinks = _objectList(json['shareLinks']).map((item) {
      final copy = Map<String, dynamic>.from(item);
      final relativeUrl = copy['relativeUrl'] as String?;
      if (relativeUrl != null && relativeUrl.isNotEmpty) {
        copy['publicUrl'] = baseUri
            .resolve(relativeUrl.startsWith('/')
                ? relativeUrl.substring(1)
                : relativeUrl)
            .toString();
      }
      return copy;
    }).toList(growable: false);
    return StudioRemoteSnapshot(
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      snapshot: _object(json['snapshot']),
      members: _objectList(json['members']),
      shareLinks: shareLinks,
    );
  }

  Future<int> putSnapshot({
    required String accessToken,
    required String workspaceId,
    required int baseRevision,
    required Map<String, dynamic> snapshot,
  }) async {
    final json = await _request(
      'PUT',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/snapshot',
      accessToken,
      body: {'baseRevision': baseRevision, 'snapshot': snapshot},
    );
    return (json['revision'] as num?)?.toInt() ?? baseRevision + 1;
  }

  Future<void> upsertMember({
    required String accessToken,
    required String workspaceId,
    required String email,
    required String displayName,
    required String role,
  }) async {
    await _request(
      'POST',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/members',
      accessToken,
      body: {
        'email': email,
        'displayName': displayName,
        'role': role,
      },
    );
  }

  Future<void> deactivateMember({
    required String accessToken,
    required String workspaceId,
    required String memberId,
  }) async {
    await _request(
      'DELETE',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/members/${Uri.encodeComponent(memberId)}',
      accessToken,
    );
  }

  Future<Map<String, dynamic>> getFarmOrganization({
    required String accessToken,
    required String organizationId,
  }) {
    return _request(
      'GET',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}',
      accessToken,
    );
  }

  Future<Map<String, dynamic>> updateFarmOrganization({
    required String accessToken,
    required String organizationId,
    required Map<String, dynamic> profile,
  }) {
    return _request(
      'PATCH',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}',
      accessToken,
      body: profile,
    );
  }

  Future<Map<String, dynamic>> submitFarmVerification({
    required String accessToken,
    required String organizationId,
    List<String> documentManifest = const [],
  }) {
    return _request(
      'POST',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}/verification-submissions',
      accessToken,
      body: {'documentManifest': documentManifest},
    );
  }

  Future<Map<String, dynamic>> createFarmStaff({
    required String accessToken,
    required String organizationId,
    required String displayName,
    required String loginName,
    required List<String> roleCodes,
    String? primaryRoleCode,
    String? employeeNo,
    String? phone,
    String? recoveryEmail,
    List<Map<String, dynamic>> scopes = const [
      {'type': 'organization', 'id': null},
    ],
  }) {
    return _request(
      'POST',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}/staff',
      accessToken,
      body: {
        'displayName': displayName,
        'loginName': loginName,
        'roleCodes': roleCodes,
        'primaryRoleCode': primaryRoleCode ?? roleCodes.first,
        if (employeeNo != null && employeeNo.trim().isNotEmpty)
          'employeeNo': employeeNo.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (recoveryEmail != null && recoveryEmail.trim().isNotEmpty)
          'recoveryEmail': recoveryEmail.trim(),
        'scopes': scopes,
      },
    );
  }

  Future<Map<String, dynamic>> updateFarmStaff({
    required String accessToken,
    required String organizationId,
    required String memberId,
    String? displayName,
    List<String>? roleCodes,
    String? primaryRoleCode,
    String? accountStatus,
  }) {
    return _request(
      'PATCH',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}/staff/${Uri.encodeComponent(memberId)}',
      accessToken,
      body: {
        if (displayName != null) 'displayName': displayName,
        if (roleCodes != null) 'roleCodes': roleCodes,
        if (primaryRoleCode != null) 'primaryRoleCode': primaryRoleCode,
        if (accountStatus != null) 'accountStatus': accountStatus,
      },
    );
  }

  Future<Map<String, dynamic>> resetFarmStaffCredential({
    required String accessToken,
    required String organizationId,
    required String memberId,
  }) {
    return _request(
      'POST',
      '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}/staff/${Uri.encodeComponent(memberId)}/reset-credential',
      accessToken,
      body: const {},
    );
  }

  Future<List<StudioRemoteAuditLog>> getFarmAuditLogs({
    required String accessToken,
    required String organizationId,
  }) async {
    const pageSize = 500;
    var offset = 0;
    final result = <StudioRemoteAuditLog>[];
    while (true) {
      final json = await _request(
        'GET',
        '/v1/farm/organizations/${Uri.encodeComponent(organizationId)}/audit-logs'
            '?limit=$pageSize&offset=$offset',
        accessToken,
      );
      final items = _objectList(json['items']);
      for (final item in items) {
        final id = item['id'] as String?;
        final action = item['action'] as String?;
        final createdAt = DateTime.tryParse(item['createdAt'] as String? ?? '');
        if (id == null || action == null || createdAt == null) continue;
        result.add(
          StudioRemoteAuditLog(
            id: id,
            clientEventId: item['clientEventId'] as String?,
            action: action,
            result: item['result'] as String? ?? 'success',
            createdAt: createdAt.toLocal(),
            actorName: item['actorName'] as String?,
            actorIdentity: item['actorIdentity'] as String?,
            actorMemberId: item['actorMemberId'] as String?,
            resourceType: item['resourceType'] as String?,
            resourceId: item['resourceId'] as String?,
            summary: item['summary'] as String?,
          ),
        );
      }
      if (items.length < pageSize || json['hasMore'] != true) break;
      offset += items.length;
      // A corrupt server must not turn opening the audit page into an
      // unbounded request loop. Records remain stored server-side.
      if (offset >= 50000) break;
    }
    return result;
  }

  Future<StudioRemoteShareLink> createShareLink({
    required String accessToken,
    required String workspaceId,
    required String orderId,
    int expiresInDays = 30,
    required String portalPassword,
  }) async {
    final json = await _request(
      'POST',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/share-links',
      accessToken,
      body: {
        'orderId': orderId,
        'expiresInDays': expiresInDays,
        'portalPassword': portalPassword,
      },
    );
    final relative = json['relativeUrl'] as String?;
    if (relative == null) {
      throw const StudioCloudException('服务器没有返回客户进度链接');
    }
    return StudioRemoteShareLink(
      id: json['id'] as String,
      tokenPreview: json['tokenPreview'] as String? ?? '',
      publicUrl: baseUri
          .resolve(relative.startsWith('/') ? relative.substring(1) : relative),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  Future<StudioVideoUplinkSession> createVideoSession({
    required String accessToken,
    required String workspaceId,
    required String orderId,
    required String workOrderId,
    required String publicPrinterName,
  }) async {
    final json = await _request(
      'POST',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/video-sessions',
      accessToken,
      body: {
        'orderId': orderId,
        'workOrderId': workOrderId,
        'publicPrinterName': publicPrinterName,
      },
    );
    final transport = json['transport'] as String? ?? 'jpeg';
    final uploadPath = json['uploadPath'] as String?;
    final pushUrl = json['pushUrl'] as String?;
    if (transport == 'rtmp' && pushUrl == null) {
      throw const StudioCloudException('服务器没有返回直播推流地址');
    }
    if (transport != 'rtmp' && uploadPath == null) {
      throw const StudioCloudException('服务器没有返回视频上行地址');
    }
    return StudioVideoUplinkSession(
      id: json['id'] as String,
      transport: transport,
      uploadToken: json['uploadToken'] as String?,
      uploadUri: uploadPath == null
          ? null
          : baseUri.resolve(
              uploadPath.startsWith('/') ? uploadPath.substring(1) : uploadPath,
            ),
      pushUri: pushUrl == null ? null : Uri.parse(pushUrl),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  Future<List<StudioVideoDemand>> listVideoDemand({
    required String accessToken,
    required String workspaceId,
  }) async {
    final json = await _request(
      'GET',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/video-demand',
      accessToken,
    );
    return _objectList(json['items']).map((item) {
      return StudioVideoDemand(
        orderId: item['orderId'] as String,
        workOrderId: item['workOrderId'] as String,
        viewerCount: (item['viewerCount'] as num?)?.toInt() ?? 0,
        expiresAt: DateTime.parse(item['expiresAt'] as String),
      );
    }).toList(growable: false);
  }

  Future<void> stopVideoSession({
    required String accessToken,
    required String workspaceId,
    required String sessionId,
  }) async {
    await _request(
      'DELETE',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/video-sessions/${Uri.encodeComponent(sessionId)}',
      accessToken,
    );
  }

  Future<void> uploadVideoFrame({
    required StudioVideoUplinkSession session,
    required Uint8List jpeg,
  }) async {
    final uploadUri = session.uploadUri;
    final uploadToken = session.uploadToken;
    if (uploadUri == null || uploadToken == null) {
      throw const StudioCloudException('此视频会话不接受 JPEG 帧上传');
    }
    final response = await _httpClient.put(
      uploadUri,
      headers: {
        'Authorization': 'Bearer $uploadToken',
        'Content-Type': 'image/jpeg',
        'Accept': 'application/json',
      },
      body: jpeg,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    Map<String, dynamic> json = const {};
    if (response.bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    }
    final error = _object(json['error']);
    throw StudioCloudException(
      error['message'] as String? ?? '视频帧上传失败',
      code: error['code'] as String?,
      statusCode: response.statusCode,
    );
  }

  Future<void> revokeShareLink({
    required String accessToken,
    required String workspaceId,
    required String shareId,
  }) async {
    await _request(
      'DELETE',
      '/v1/studio/workspaces/${Uri.encodeComponent(workspaceId)}/share-links/${Uri.encodeComponent(shareId)}',
      accessToken,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    String accessToken, {
    Map<String, dynamic>? body,
  }) async {
    final uri =
        baseUri.resolve(path.startsWith('/') ? path.substring(1) : path);
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    late final http.Response response;
    switch (method) {
      case 'GET':
        response = await _httpClient.get(uri, headers: headers);
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'PUT':
        response = await _httpClient.put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'PATCH':
        response = await _httpClient.patch(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'DELETE':
        response = await _httpClient.delete(uri, headers: headers);
      default:
        throw StudioCloudException('不支持的请求方法：$method');
    }
    Map<String, dynamic> json = const {};
    if (response.bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _object(json['error']);
      throw StudioCloudException(
        error['message'] as String? ?? '工作室云请求失败',
        code: error['code'] as String?,
        statusCode: response.statusCode,
      );
    }
    return json;
  }

  static Uri _normalize(Uri value) {
    final text = value.toString();
    return Uri.parse(text.endsWith('/') ? text : '$text/');
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, item) => MapEntry('$key', item));
    return <String, dynamic>{};
  }

  static List<Map<String, dynamic>> _objectList(Object? value) {
    if (value is! List) return const [];
    return value.map(_object).toList(growable: false);
  }
}
