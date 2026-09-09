import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/windows_dpapi.dart';
import '../../mobile/ams_tag_template.dart';
import '../../mobile/ams_template_repository.dart';

/// DPAPI-protected, account-bound local vault. Never uploads templates/keys.
/// A failed decryption never creates an empty replacement vault.
class DesktopTemplateRepository extends AmsTemplateRepository {
  DesktopTemplateRepository({this.protector = const WindowsDpapiProtector()});
  final DataProtector protector;
  static Future<void> _tail = Future<void>.value();

  String _owner(String owner) {
    final value = owner.trim().toLowerCase();
    if (value.length > 400 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('账号标识无效');
    }
    return value;
  }

  String _key(String owner) =>
      'desktop_rfid_vault_v1_${sha256.convert(utf8.encode(owner))}';

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<List<AmsTagTemplate>> _read(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(owner));
    if (raw == null) return [];
    try {
      if (raw.length > 1000000) throw const FormatException();
      final bytes = await protector.unprotect(base64Decode(raw));
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map ||
          data['owner'] != owner ||
          data['version'] != 1 ||
          data['templates'] is! List ||
          (data['templates'] as List).length > 128) {
        throw const FormatException();
      }
      return [
        for (final t in data['templates'] as List)
          AmsTagTemplate.fromJson(Map<String, dynamic>.from(t as Map)),
      ];
    } catch (_) {
      throw const FormatException('本机模板库解密或校验失败；不会覆盖原数据');
    }
  }

  Future<void> _write(String owner, List<AmsTagTemplate> templates) async {
    if (templates.length > 128) {
      throw const FormatException('本机每个账号最多保存 128 份模板');
    }
    final encrypted = await protector.protect(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'owner': owner,
            'templates': templates.map((t) => t.toJson()).toList(),
          }),
        ),
      ),
    );
    if (encrypted.isEmpty) throw const FormatException('加密保存失败');
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key(owner), base64Encode(encrypted))) {
      throw const FormatException('保存失败');
    }
  }

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) =>
      _serial(() => _read(_owner(ownerAccount)));
  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async {
    for (final t in await list(ownerAccount: ownerAccount)) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<void> save(AmsTagTemplate template, {required String ownerAccount}) =>
      _serial(() async {
        final owner = _owner(ownerAccount);
        final values = await _read(owner);
        values.removeWhere((t) => t.id == template.id);
        values.add(template);
        await _write(owner, values);
      });
  @override
  Future<void> delete(String id, {required String ownerAccount}) =>
      _serial(() async {
        final owner = _owner(ownerAccount);
        final values = await _read(owner);
        values.removeWhere((t) => t.id == id);
        await _write(owner, values);
      });
}
