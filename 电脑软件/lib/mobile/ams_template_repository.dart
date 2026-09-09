import 'package:flutter/services.dart';

import 'ams_tag_template.dart';

/// Device-only secret template storage. Never backed by inventory/cloud APIs.
abstract class AmsTemplateRepository {
  Future<List<AmsTagTemplate>> list({required String ownerAccount});
  Future<AmsTagTemplate?> read(String id, {required String ownerAccount});
  Future<void> save(AmsTagTemplate template, {required String ownerAccount});
  Future<void> delete(String id, {required String ownerAccount});
}

class MethodChannelAmsTemplateRepository implements AmsTemplateRepository {
  final MethodChannel channel;

  const MethodChannelAmsTemplateRepository({
    this.channel = const MethodChannel('top.sohun/rfid_template_vault'),
  });

  String _owner(String value) {
    final owner = value.trim().toLowerCase();
    if (owner.length > 320 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(owner)) {
      throw const FormatException('账号标识无效。');
    }
    return owner;
  }

  void _validateId(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('模板标识无效。');
    }
  }

  AmsTagTemplate _decode(Object? value) {
    if (value is! Map) throw const FormatException('本机模板数据损坏。');
    try {
      return AmsTagTemplate.fromJson(Map<String, dynamic>.from(value));
    } catch (_) {
      throw const FormatException('本机模板校验失败，请重新导入原始文件。');
    }
  }

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async {
    final result = await channel.invokeMethod<Object?>('listTemplates', {
      'ownerAccount': _owner(ownerAccount),
    });
    if (result is! List || result.length > 128) {
      throw const FormatException('本机模板列表损坏。');
    }
    return List<AmsTagTemplate>.unmodifiable(result.map(_decode));
  }

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async {
    _validateId(id);
    final result = await channel.invokeMethod<Object?>('readTemplate', {
      'ownerAccount': _owner(ownerAccount),
      'id': id,
    });
    if (result == null) return null;
    final template = _decode(result);
    if (template.id != id) throw const FormatException('本机模板标识不一致。');
    return template;
  }

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {
    await channel.invokeMethod<void>('saveTemplate', {
      'ownerAccount': _owner(ownerAccount),
      'template': template.toJson(),
    });
  }

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {
    _validateId(id);
    await channel.invokeMethod<void>('deleteTemplate', {
      'ownerAccount': _owner(ownerAccount),
      'id': id,
    });
  }
}
