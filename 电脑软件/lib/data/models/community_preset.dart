import 'dart:convert';

import 'print_parameter.dart';

class CommunityPresetOwner {
  /// Present only for legacy servers or for responses about the signed-in
  /// user's own publication. Public feeds must not expose internal user IDs.
  final String? id;
  final String handle;
  final String displayName;
  final String? avatarUrl;

  const CommunityPresetOwner({
    this.id,
    required this.handle,
    required this.displayName,
    this.avatarUrl,
  });

  factory CommunityPresetOwner.fromJson(Map<String, dynamic> json) {
    return CommunityPresetOwner(
      id: _optionalText(json['id']),
      handle: _requiredText(json['handle'], 'owner.handle'),
      displayName: _requiredText(
        json['displayName'] ?? json['display_name'],
        'owner.displayName',
      ),
      avatarUrl: _optionalText(json['avatarUrl'] ?? json['avatar_url']),
    );
  }
}

/// A public-workbench publication. Bambu's `shareId` never appears here.
class CommunityPreset {
  final String publicationId;
  final CommunityPresetOwner owner;
  final PrintParameterPreset preset;
  final String visibility;
  final int revision;
  final String? versionId;
  final String? contentHash;
  final int likes;
  final int downloads;
  final int applicationCount;
  final bool likedByMe;
  final bool ownedByMe;
  final String moderationStatus;
  final DateTime publishedAt;
  final DateTime updatedAt;

  const CommunityPreset({
    required this.publicationId,
    required this.owner,
    required this.preset,
    required this.visibility,
    required this.revision,
    this.versionId,
    this.contentHash,
    required this.likes,
    required this.downloads,
    this.applicationCount = 0,
    required this.likedByMe,
    this.ownedByMe = false,
    this.moderationStatus = 'published',
    required this.publishedAt,
    required this.updatedAt,
  });

  factory CommunityPreset.fromJson(Map<String, dynamic> json) {
    final rawOwner = json['owner'];
    final rawPreset = json['preset'];
    if (rawOwner is! Map || rawPreset is! Map) {
      throw const FormatException('社区参数缺少作者或参数内容');
    }
    final publicationId = _requiredText(json['id'], 'id');
    final owner = CommunityPresetOwner.fromJson(
      Map<String, dynamic>.from(rawOwner),
    );
    final decodedPreset = PrintParameterPreset.fromBbsparamJson(
      jsonEncode(Map<String, dynamic>.from(rawPreset)),
    );
    final publishedAt = _requiredDate(
      json['publishedAt'] ?? json['published_at'],
      'publishedAt',
    );
    final updatedAt = _optionalDate(
          json['updatedAt'] ?? json['updated_at'],
        ) ??
        publishedAt;
    return CommunityPreset(
      publicationId: publicationId,
      owner: owner,
      preset: decodedPreset.copyWith(
        id: 'community_$publicationId',
        author: owner.displayName,
        avatarUrl: owner.avatarUrl,
        shareId: null,
        uploadedAt: null,
        serverVersion: null,
        communityPublicationId: null,
        communityOwnerId: null,
        communityRevision: null,
        communityVisibility: null,
        likes: _integer(json['likes']),
        downloads: _integer(json['downloads']),
        updatedAt: updatedAt,
      ),
      visibility: _optionalText(json['visibility']) ?? 'public',
      revision: _integer(json['revision'], fallback: 1),
      versionId: _optionalText(json['versionId'] ?? json['version_id']),
      contentHash: _optionalText(json['contentHash'] ?? json['content_hash']),
      likes: _integer(json['likes']),
      downloads: _integer(json['downloads']),
      applicationCount:
          _integer(json['applicationCount'] ?? json['application_count']),
      likedByMe: json['likedByMe'] == true || json['liked_by_me'] == true,
      ownedByMe: json['ownedByMe'] == true || json['owned_by_me'] == true,
      moderationStatus: _optionalText(
            json['moderationStatus'] ?? json['moderation_status'],
          ) ??
          'published',
      publishedAt: publishedAt,
      updatedAt: updatedAt,
    );
  }

  CommunityPreset copyWith({
    PrintParameterPreset? preset,
    int? likes,
    int? downloads,
    int? applicationCount,
    bool? likedByMe,
    bool? ownedByMe,
    int? revision,
    DateTime? updatedAt,
  }) {
    final nextLikes = likes ?? this.likes;
    final nextDownloads = downloads ?? this.downloads;
    return CommunityPreset(
      publicationId: publicationId,
      owner: owner,
      preset: (preset ?? this.preset).copyWith(
        likes: nextLikes,
        downloads: nextDownloads,
      ),
      visibility: visibility,
      revision: revision ?? this.revision,
      versionId: versionId,
      contentHash: contentHash,
      likes: nextLikes,
      downloads: nextDownloads,
      applicationCount: applicationCount ?? this.applicationCount,
      likedByMe: likedByMe ?? this.likedByMe,
      ownedByMe: ownedByMe ?? this.ownedByMe,
      moderationStatus: moderationStatus,
      publishedAt: publishedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class CommunityPresetPage {
  final List<CommunityPreset> items;
  final String? nextCursor;

  const CommunityPresetPage({
    required this.items,
    this.nextCursor,
  });

  factory CommunityPresetPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('社区参数列表格式不正确');
    }
    return CommunityPresetPage(
      items: rawItems
          .whereType<Map>()
          .map(
            (item) => CommunityPreset.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .toList(growable: false),
      nextCursor: _optionalText(json['nextCursor'] ?? json['next_cursor']),
    );
  }
}

String _requiredText(dynamic value, String field) {
  final result = _optionalText(value);
  if (result == null) throw FormatException('字段 $field 缺失');
  return result;
}

String? _optionalText(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int _integer(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime _requiredDate(dynamic value, String field) {
  final date = _optionalDate(value);
  if (date == null) throw FormatException('字段 $field 格式不正确');
  return date;
}

DateTime? _optionalDate(dynamic value) {
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  if (value is num) {
    final millis = value > 100000000000 ? value.toInt() : value.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  }
  return null;
}
