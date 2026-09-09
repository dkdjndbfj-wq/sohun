import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bambu_cloud_models.dart';

/// 拓竹云账号凭据加密存储。
///
/// 用 AES-256-CBC 加密账号密码，密钥由本机机器名 + 用户名派生，
/// 加密后存到 shared_preferences。
///
/// **安全模型**：
/// - 密钥绑定本机本用户（机器名+用户名），换电脑/换用户无法解密
/// - AES-256-CBC + 随机 IV，每次加密结果不同
/// - 活跃账号 key 也加密存储（不暴露用户邮箱到明文 prefs）
/// - 写操作有并发保护（Completer 串行化），避免 last-write-wins
///
/// **异常策略**：
/// - 读操作失败返回空/null（兼容首次启动无数据场景）
/// - 写操作失败抛异常（调用方应捕获并反馈给用户）
/// - 解密失败抛 [StateError]（数据损坏或跨机器迁移时）
///
/// **多账号支持**：
/// - 同时保存多个拓竹账号（不同邮箱，或同邮箱不同区域）
/// - 通过加密的活跃账号 key 标识当前账号
/// - 账号唯一标识为 email + region（同一邮箱可同时在中国区和海外区注册）
class BambuCloudSessionStore {
  /// 旧版单账号存储键（保留用于迁移，不再用于读写）
  static const _keyAccount = 'bambu_cloud_account_enc';
  static const _keySession = 'bambu_cloud_session_enc';

  /// 多账号列表存储键（加密后存数组 JSON）
  static const _keyAccountsList = 'bambu_cloud_accounts_list_enc';
  static const _keySessionsList = 'bambu_cloud_sessions_list_enc';

  /// 当前活跃账号标识（加密存储，"email|region_code" 格式）
  static const _keyActiveAccountEmail = 'bambu_cloud_active_account_email_enc';

  // ===== 并发保护 =====
  // 用 Completer 串行化所有写操作，避免并发 upsert 导致 last-write-wins。
  static Completer<void>? _writeLock;

  static Future<T> _withWriteLock<T>(Future<T> Function() action) async {
    // 如果有正在进行的写操作，等待它完成
    while (_writeLock != null) {
      try {
        await _writeLock!.future;
      } catch (_) {}
    }
    final completer = Completer<void>();
    _writeLock = completer;
    try {
      return await action();
    } finally {
      // This future is only a lock-release signal. Report an action failure
      // through its caller, not an unobserved completer that raises a second
      // uncaught asynchronous error when there is no waiting writer.
      _writeLock = null;
      completer.complete();
    }
  }

  // ===== 加密基础 =====

  /// 密文版本前缀：v2 = PBKDF2 + 每安装随机 salt；无前缀 = 旧版（单次 SHA-256）。
  static const _cipherV2Prefix = 'v2:';
  static const _dpapiPrefix = 'dpapi:';
  static const _securityChannel = MethodChannel('consumable_tracker/security');
  static Future<Key>? _derivedV2Key;

  /// 获取本安装的随机 salt（首次调用生成并持久化）。
  /// 与机器名/用户名绑定的派生材料一起作为 PBKDF2 输入，显著提升抗离线暴力强度。
  static Future<String> _getOrCreateSalt(SharedPreferences prefs) async {
    var salt = prefs.getString('bambu_kdf_salt');
    if (salt == null || salt.isEmpty) {
      final rand = Random.secure();
      final bytes = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        bytes[i] = rand.nextInt(256);
      }
      salt = base64Encode(bytes);
      await prefs.setString('bambu_kdf_salt', salt);
    }
    return salt;
  }

  /// 加密：明文 → base64(ciphertext + IV)，使用 v2 密钥派生。
  static Future<String> _encrypt(String plaintext) async {
    if (Platform.isWindows) {
      final protected = await _securityChannel.invokeMethod<Uint8List>(
        'protect',
        Uint8List.fromList(utf8.encode(plaintext)),
      );
      if (protected == null) {
        throw StateError('Windows DPAPI 未返回加密结果');
      }
      return '$_dpapiPrefix${base64Encode(protected)}';
    }
    final prefs = await SharedPreferences.getInstance();
    final key = await _deriveKeyV2(prefs);
    final iv = IV.fromSecureRandom(16);
    final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    // 把 IV 拼到密文前面，解密时切开
    final combined = utf8.encode(iv.base64) + [0x00] + encrypted.bytes;
    return '$_cipherV2Prefix${base64Encode(combined)}';
  }

  /// 解密：自动识别 v2 / 旧版密文，分别走对应派生路径。
  ///
  /// **安全（M4 修复）**：旧版密文解密成功后立即用 v2 重新加密写回原 key，
  /// 强制升级，避免弱派生密文长期留存。升级失败不中断解密流程（仅记录日志）。
  static Future<String> _decrypt(String ciphertextBase64) async {
    try {
      if (ciphertextBase64.startsWith(_dpapiPrefix)) {
        final cipherBytes = Uint8List.fromList(
          base64Decode(ciphertextBase64.substring(_dpapiPrefix.length)),
        );
        final plaintext = await _securityChannel.invokeMethod<Uint8List>(
          'unprotect',
          cipherBytes,
        );
        if (plaintext == null) throw StateError('Windows DPAPI 未返回解密结果');
        return utf8.decode(plaintext);
      }
      final isV2 = ciphertextBase64.startsWith(_cipherV2Prefix);
      final combined = isV2
          ? base64Decode(ciphertextBase64.substring(_cipherV2Prefix.length))
          : base64Decode(ciphertextBase64);
      // 找分隔符 0x00 切分 IV 和密文
      final sepIdx = combined.indexOf(0x00);
      if (sepIdx < 0) throw const FormatException('密文格式异常');
      final ivBytes = combined.sublist(0, sepIdx);
      final ctBytes = combined.sublist(sepIdx + 1);
      final iv = IV.fromBase64(utf8.decode(ivBytes));
      final key = isV2
          ? await _deriveKeyV2(await SharedPreferences.getInstance())
          : _deriveKeyLegacy();
      final encrypter = Encrypter(AES(key, mode: AESMode.cbc));
      // decrypt 直接返回 UTF-8 解码后的字符串（明文是 JSON）
      final plaintext = encrypter.decrypt(
        Encrypted(Uint8List.fromList(ctBytes)),
        iv: iv,
      );

      // M4 修复：legacy 密文解密成功后，立即用 v2 重新加密并写回原存储 key。
      // 这样旧版弱派生密文不会长期留存，攻击者无法用硬编码 salt 离线爆破。
      // AES 旧格式一旦成功读取，立即迁移到 DPAPI（非 Windows 则迁移到 v2）。
      if (!isV2 || Platform.isWindows) {
        await _upgradeLegacyCipher(ciphertextBase64, plaintext);
      }
      return plaintext;
    } catch (e) {
      throw StateError('解密账号信息失败: $e');
    }
  }

  /// 把 legacy 密文升级为 v2 密文，写回所有可能的存储 key。
  ///
  /// legacy 密文可能存在于多个 key（单账号/多账号列表/session 列表/活跃账号）。
  /// 找到匹配的 key 后用 v2 重新加密写回。失败仅记录日志，不中断主流程。
  static Future<void> _upgradeLegacyCipher(
    String legacyCipher,
    String plaintext,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v2Encrypted = await _encrypt(plaintext);
      // 检查所有可能的存储 key，找到 legacy 密文并替换
      final keysToCheck = [
        _keyAccount,
        _keySession,
        _keyAccountsList,
        _keySessionsList,
        _keyActiveAccountEmail,
      ];
      for (final key in keysToCheck) {
        final stored = prefs.getString(key);
        if (stored == legacyCipher) {
          await prefs.setString(key, v2Encrypted);
          debugPrint('[SessionStore] 已将 $key 从 legacy 升级到 v2');
        }
      }
    } catch (e) {
      debugPrint('[SessionStore] legacy 升级失败（非致命）: $e');
    }
  }

  /// v2 派生：PBKDF2-HMAC-SHA256(机器名+用户名+本地随机secret, 每安装随机salt, 100000 轮) → 32 字节。
  ///
  /// **安全（M2 修复）**：在派生材料中加入本地随机 secret（独立文件存储 + ACL 保护），
  /// 攻击者仅凭机器名+用户名+SharedPreferences 无法离线爆破，还需获取独立存储的
  /// secret 文件。secret 首次调用时生成，存到 `getApplicationSupportDirectory` 下，
  /// 用 icacls 设置 ACL 限制只有当前用户可读。
  static Future<Key> _deriveKeyV2(SharedPreferences prefs) async {
    final cached = _derivedV2Key;
    if (cached != null) return cached;
    final future = _deriveKeyV2Uncached(prefs);
    _derivedV2Key = future;
    try {
      return await future;
    } catch (_) {
      // A transient platform/storage failure must not poison the cache for the
      // rest of the process.  The next read can retry key derivation.
      if (identical(_derivedV2Key, future)) _derivedV2Key = null;
      rethrow;
    }
  }

  static Future<Key> _deriveKeyV2Uncached(SharedPreferences prefs) async {
    final machine =
        Platform.environment['COMPUTERNAME'] ??
        Platform.environment['HOSTNAME'] ??
        'unknown_machine';
    final user =
        Platform.environment['USERNAME'] ??
        Platform.environment['USER'] ??
        'unknown_user';
    final salt = await _getOrCreateSalt(prefs);
    // M2 修复：加入本地随机 secret，提升离线爆破难度
    final localSecret = await _getOrCreateLocalSecret();
    final passphrase = utf8.encode('$machine|$user|$localSecret');
    final saltBytes = utf8.encode(salt);
    final derived = _pbkdf2(passphrase, saltBytes, 100000, 32);
    return Key(Uint8List.fromList(derived));
  }

  /// 获取或创建本地随机 secret（M2 修复）。
  ///
  /// 首次调用时生成 32 字节随机数，base64 编码后存到
  /// `getApplicationSupportDirectory/bambu_key_secret` 文件，
  /// 并用 icacls 设置 ACL 限制只有当前用户可读。
  /// 后续调用直接读取该文件。
  static Future<String> _getOrCreateLocalSecret() async {
    try {
      final dir = await _getSecureDir();
      // Use the platform-aware path package.  The old hard-coded backslash
      // produced a filename containing a literal '\\' on Android/Linux,
      // preventing the secret from surviving a second launch.
      final secretFile = File(p.join(dir.path, 'bambu_key_secret'));
      if (secretFile.existsSync()) {
        return secretFile.readAsStringSync().trim();
      }
      // 生成 32 字节随机 secret
      final rand = Random.secure();
      final bytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        bytes[i] = rand.nextInt(256);
      }
      final secret = base64Encode(bytes);
      secretFile.writeAsStringSync(secret);
      // 设置 ACL：仅当前用户可读写
      await _restrictSecretAcl(secretFile.path);
      return secret;
    } catch (e) {
      throw StateError('本地凭据密钥不可用，已停止读取账号数据: $e');
    }
  }

  /// 获取安全的存储目录（applicationSupportDirectory）。
  static Future<Directory> _getSecureDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    } catch (e) {
      throw StateError('无法访问应用安全目录: $e');
    }
  }

  /// 用 icacls 限制 secret 文件 ACL，仅当前用户可读写。
  static Future<void> _restrictSecretAcl(String filePath) async {
    try {
      final user = Platform.environment['USERNAME'] ?? '';
      if (user.isEmpty) return;
      final result = await Process.run('icacls', [
        filePath,
        '/inheritance:r',
        '/grant:r',
        '$user:F',
      ]);
      if (result.exitCode != 0) {
        debugPrint('[SessionStore] secret ACL 设置失败（非致命）: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('[SessionStore] secret icacls 调用失败（非致命）: $e');
    }
  }

  /// 旧版派生（仅用于解密历史密文，向后兼容）。
  static Key _deriveKeyLegacy() {
    const salt = 'consumable_tracker_bambu_v1';
    final machine =
        Platform.environment['COMPUTERNAME'] ??
        Platform.environment['HOSTNAME'] ??
        'unknown_machine';
    final user =
        Platform.environment['USERNAME'] ??
        Platform.environment['USER'] ??
        'unknown_user';
    final material = '$machine|$user|$salt';
    final digest = crypto.sha256.convert(utf8.encode(material));
    return Key(Uint8List.fromList(digest.bytes));
  }

  /// PBKDF2-HMAC-SHA256 实现（标准 RFC 2898）。
  /// 不引入额外依赖，用 crypto 包的 Hmac 组合。
  static Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLen,
  ) {
    final hmac = crypto.Hmac(crypto.sha256, password);
    final blockCount = (keyLen + 31) ~/ 32;
    final out = <int>[];
    for (var i = 1; i <= blockCount; i++) {
      final u = hmac.convert([
        ...salt,
        (i >> 24) & 0xff,
        (i >> 16) & 0xff,
        (i >> 8) & 0xff,
        i & 0xff,
      ]).bytes;
      var t = List<int>.from(u);
      for (var j = 1; j < iterations; j++) {
        final u2 = hmac.convert(t).bytes;
        for (var k = 0; k < 32; k++) {
          t[k] ^= u2[k];
        }
      }
      out.addAll(t);
    }
    return Uint8List.fromList(out.sublist(0, keyLen));
  }

  /// 生成账号唯一 key（用于内部匹配），格式 "email|region_code"。
  static String _accountKey(String email, BambuRegion region) =>
      '$email|${region.code}';

  /// 解析活跃账号 key（"email|region_code"）为 email + region。
  /// 用 lastIndexOf 反向切分，兼容 email 含 '|' 的极端情况。
  static _ActiveKey? _parseActiveKey(String? key) {
    if (key == null || key.isEmpty) return null;
    final idx = key.lastIndexOf('|');
    if (idx < 0) return null;
    final email = key.substring(0, idx);
    final regionCode = key.substring(idx + 1);
    final region = regionCode == 'Overseas'
        ? BambuRegion.overseas
        : BambuRegion.china;
    return _ActiveKey(email: email, region: region);
  }

  // ===== 多账号 API（写操作有并发保护，失败抛异常）=====

  /// 保存账号到列表（如已存在同 email+region 则更新密码）。
  ///
  /// 抛异常场景：存储失败、加密失败、SharedPreferences 不可用。
  static Future<void> upsertAccount(BambuCloudAccount account) async {
    await _withWriteLock(() async {
      final accounts = await _loadAllAccountsUnsafe();
      final idx = accounts.indexWhere(
        (a) => a.email == account.email && a.region == account.region,
      );
      if (idx >= 0) {
        accounts[idx] = account;
      } else {
        accounts.add(account);
      }
      await _writeAccountsList(accounts);
    });
  }

  /// 读取所有已存储的账号列表。
  /// 没有数据时返回空列表；已有密文但解密失败时抛错，禁止伪装成账号被清空。
  static Future<List<BambuCloudAccount>> loadAllAccounts() async {
    return _loadAllAccountsUnsafe();
  }

  static Future<List<BambuCloudAccount>> _loadAllAccountsUnsafe() async {
    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getString(_keyAccountsList);
    if (encrypted == null || encrypted.isEmpty) return [];
    final json = jsonDecode(await _decrypt(encrypted)) as List<dynamic>;
    return json
        .map((e) => BambuCloudAccount.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 删除指定账号（按 email+region 匹配）。
  static Future<void> removeAccount(String email, BambuRegion region) async {
    await _withWriteLock(() async {
      final accounts = await _loadAllAccountsUnsafe();
      accounts.removeWhere((a) => a.email == email && a.region == region);
      await _writeAccountsList(accounts);
    });
  }

  /// 保存 session 到列表（按 email+region 匹配更新）。
  static Future<void> upsertSession(BambuCloudSession session) async {
    await _withWriteLock(() async {
      final sessions = await _loadAllSessionsUnsafe();
      final idx = sessions.indexWhere(
        (s) => s.email == session.email && s.region == session.region,
      );
      if (idx >= 0) {
        sessions[idx] = session;
      } else {
        sessions.add(session);
      }
      await _writeSessionsList(sessions);
    });
  }

  /// 读取所有已存储的 session 列表。
  static Future<List<BambuCloudSession>> loadAllSessions() async {
    return _loadAllSessionsUnsafe();
  }

  static Future<List<BambuCloudSession>> _loadAllSessionsUnsafe() async {
    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getString(_keySessionsList);
    if (encrypted == null || encrypted.isEmpty) return [];
    final json = jsonDecode(await _decrypt(encrypted)) as List<dynamic>;
    return json
        .map((e) => BambuCloudSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 读取指定账号的 session。
  static Future<BambuCloudSession?> loadSessionFor(
    String email,
    BambuRegion region,
  ) async {
    final sessions = await loadAllSessions();
    for (final s in sessions) {
      if (s.email == email && s.region == region) return s;
    }
    return null;
  }

  /// 删除指定账号的 session。
  static Future<void> removeSession(String email, BambuRegion region) async {
    await _withWriteLock(() async {
      final sessions = await _loadAllSessionsUnsafe();
      sessions.removeWhere((s) => s.email == email && s.region == region);
      await _writeSessionsList(sessions);
    });
  }

  // ===== 活跃账号（加密存储）=====

  /// 设置当前活跃账号（email+region 作为唯一标识）。
  static Future<void> setActiveAccount(String email, BambuRegion region) async {
    await _withWriteLock(() async {
      final prefs = await SharedPreferences.getInstance();
      final encrypted = await _encrypt(_accountKey(email, region));
      await prefs.setString(_keyActiveAccountEmail, encrypted);
    });
  }

  /// 读取当前活跃账号标识（返回 "email|region_code" 或 null）。
  static Future<String?> loadActiveAccountKey() async {
    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getString(_keyActiveAccountEmail);
    if (encrypted == null || encrypted.isEmpty) {
      // 兼容旧版明文存储（迁移期）
      final legacy = prefs.getString('bambu_cloud_active_account_email');
      if (legacy != null && legacy.isNotEmpty) {
        // 迁移到加密存储后删除旧键
        await _migrateActiveKeyToEncrypted(legacy);
        return legacy;
      }
      return null;
    }
    return _decrypt(encrypted);
  }

  /// 把旧版明文活跃 key 迁移到加密存储。
  static Future<void> _migrateActiveKeyToEncrypted(String plainKey) async {
    await _withWriteLock(() async {
      final prefs = await SharedPreferences.getInstance();
      final encrypted = await _encrypt(plainKey);
      await prefs.setString(_keyActiveAccountEmail, encrypted);
      await prefs.remove('bambu_cloud_active_account_email');
    });
  }

  /// 清除当前活跃账号标识（不删除账号数据）。
  static Future<void> clearActiveAccount() async {
    await _withWriteLock(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyActiveAccountEmail);
      // 兼容旧版明文键
      await prefs.remove('bambu_cloud_active_account_email');
    });
  }

  // ===== 内部辅助：写入列表 =====

  static Future<void> _writeAccountsList(
    List<BambuCloudAccount> accounts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(accounts.map((a) => a.toJson()).toList());
    final encrypted = await _encrypt(json);
    await prefs.setString(_keyAccountsList, encrypted);
  }

  static Future<void> _writeSessionsList(
    List<BambuCloudSession> sessions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(sessions.map((s) => s.toJson()).toList());
    final encrypted = await _encrypt(json);
    await prefs.setString(_keySessionsList, encrypted);
  }

  // ===== 向后兼容 API（操作活跃账号）=====
  // 这些方法保留以避免破坏现有调用方，但不再有隐式副作用。

  /// 保存账号凭据并设为活跃账号。
  /// 等价于 upsertAccount + setActiveAccount。
  static Future<void> saveAccount(BambuCloudAccount account) async {
    await upsertAccount(account);
    await setActiveAccount(account.email, account.region);
  }

  /// 读取当前活跃账号。未设置或列表中不存在返回 null。
  static Future<BambuCloudAccount?> loadAccount() async {
    final key = await loadActiveAccountKey();
    if (key == null) return null;
    final parsed = _parseActiveKey(key);
    if (parsed == null) return null;
    final accounts = await loadAllAccounts();
    for (final a in accounts) {
      if (a.email == parsed.email && a.region == parsed.region) return a;
    }
    return null;
  }

  /// 读取指定云账号的凭据。
  ///
  /// 云端打印机可以属于非当前活跃账号，因此连接云设备时必须按设备
  /// 归属读取账号，不能复用 [loadAccount] 的全局 active account。
  static Future<BambuCloudAccount?> loadAccountFor(
    String email,
    BambuRegion region,
  ) async {
    final accounts = await loadAllAccounts();
    for (final account in accounts) {
      if (account.email == email && account.region == region) return account;
    }
    return null;
  }

  /// 清除活跃账号标识（不删除列表中的数据）。
  static Future<void> clearAccount() async {
    await clearActiveAccount();
  }

  /// 仅清除活跃账号的 session（保留账号密码，用于 token 过期需重新登录的场景）。
  static Future<void> clearSession() async {
    final key = await loadActiveAccountKey();
    final parsed = _parseActiveKey(key);
    if (parsed == null) return;
    await removeSession(parsed.email, parsed.region);
  }

  /// 保存当前 session（登录成功后调用）。
  static Future<void> saveSession(BambuCloudSession session) async {
    await upsertSession(session);
  }

  /// 读取当前活跃账号的 session。未登录或已清除返回 null。
  static Future<BambuCloudSession?> loadSession() async {
    final key = await loadActiveAccountKey();
    final parsed = _parseActiveKey(key);
    if (parsed == null) return null;
    return loadSessionFor(parsed.email, parsed.region);
  }

  // ===== 迁移 =====

  /// 从旧版单账号存储迁移到多账号列表（启动时调用一次即可）。
  /// 使用迁移完成标志避免每次启动都检查。
  static bool _migrationCompleted = false;
  static Future<void>? _migrationInFlight;

  static Future<void> migrateFromSingleAccount() {
    if (_migrationCompleted) return Future<void>.value();
    final inFlight = _migrationInFlight;
    if (inFlight != null) return inFlight;

    final future = _migrateFromSingleAccount();
    _migrationInFlight = future;
    return future.whenComplete(() {
      if (identical(_migrationInFlight, future)) {
        _migrationInFlight = null;
      }
    });
  }

  static Future<void> _migrateFromSingleAccount() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. 迁移账号：新列表为空且旧账号存在时迁移
      final existingAccounts = await loadAllAccounts();
      if (existingAccounts.isEmpty) {
        final oldAccountEnc = prefs.getString(_keyAccount);
        if (oldAccountEnc != null && oldAccountEnc.isNotEmpty) {
          try {
            final json =
                jsonDecode(await _decrypt(oldAccountEnc))
                    as Map<String, dynamic>;
            final account = BambuCloudAccount.fromJson(json);
            await upsertAccount(account);
            await setActiveAccount(account.email, account.region);
          } catch (e) {
            debugPrint('[SessionStore] 旧账号迁移失败: $e');
          }
        }
      }

      // 2. 迁移 session：新列表为空且旧 session 存在时迁移
      final existingSessions = await loadAllSessions();
      if (existingSessions.isEmpty) {
        final oldSessionEnc = prefs.getString(_keySession);
        if (oldSessionEnc != null && oldSessionEnc.isNotEmpty) {
          try {
            final json =
                jsonDecode(await _decrypt(oldSessionEnc))
                    as Map<String, dynamic>;
            final session = BambuCloudSession.fromJson(json);
            await upsertSession(session);
          } catch (e) {
            debugPrint('[SessionStore] 旧 session 迁移失败: $e');
          }
        }
      }

      // 3. 迁移明文活跃 key 到加密存储
      final legacyActiveKey = prefs.getString(
        'bambu_cloud_active_account_email',
      );
      if (legacyActiveKey != null && legacyActiveKey.isNotEmpty) {
        await _migrateActiveKeyToEncrypted(legacyActiveKey);
      }
      // Only mark completion after every step has succeeded.  A temporary
      // SharedPreferences/DPAPI failure must be retried on the next startup.
      _migrationCompleted = true;
    } catch (e) {
      debugPrint('[SessionStore] migrateFromSingleAccount 失败: $e');
    }
  }
}

/// 活跃账号 key 解析结果（内部使用）。
class _ActiveKey {
  final String email;
  final BambuRegion region;

  const _ActiveKey({required this.email, required this.region});
}

/// 拓竹云账号凭据（邮箱+密码+区域）。
///
/// 密码加密存储，用于 token 过期后自动重新登录。
class BambuCloudAccount {
  final BambuRegion region;
  final String email;
  final String password;

  /// 用户自定义备注名（空则显示 email）。
  ///
  /// 用于在账号列表/快速切换器里显示更有辨识度的名字，
  /// 例如"公司账号"/"客户 A 账号"等。空字符串表示未设置。
  final String nickname;

  /// 是否置顶（true 时排序时永远排在最前）。
  ///
  /// 用户可右键菜单设置/取消置顶，方便常用账号快速访问。
  final bool pinned;

  /// 自定义排序序号（数字越小越靠前）。
  ///
  /// 默认为 0，用户拖拽排序时按顺序写入 1, 2, 3...
  /// 排序规则：pinned=true 优先，再按 sortOrder 升序，最后按 lastUsedAt 倒序。
  final int sortOrder;

  /// 最后一次切换到该账号的时间（用于"最近使用"排序与显示）。
  ///
  /// null 表示该账号从未被切换过（如刚添加但未激活）。
  /// 在 [BambuAccountManagerNotifier.switchAccount] 中更新。
  /// 持久化为 ISO8601 字符串；旧数据缺失时为 null。
  final DateTime? lastUsedAt;

  const BambuCloudAccount({
    required this.region,
    required this.email,
    required this.password,
    this.nickname = '',
    this.pinned = false,
    this.sortOrder = 0,
    this.lastUsedAt,
  });

  /// 显示名：优先用 nickname，空则用 email。
  String get displayName => nickname.isNotEmpty ? nickname : email;

  /// 唯一标识 key（email|region_code）。
  String get uniqueKey => '$email|${region.code}';

  BambuCloudAccount copyWith({
    String? nickname,
    bool? pinned,
    int? sortOrder,
    String? password,
    DateTime? lastUsedAt,
    bool clearLastUsedAt = false,
  }) {
    return BambuCloudAccount(
      region: region,
      email: email,
      password: password ?? this.password,
      nickname: nickname ?? this.nickname,
      pinned: pinned ?? this.pinned,
      sortOrder: sortOrder ?? this.sortOrder,
      lastUsedAt: clearLastUsedAt ? null : (lastUsedAt ?? this.lastUsedAt),
    );
  }

  Map<String, dynamic> toJson() => {
    'region': region.code,
    'email': email,
    'password': password,
    if (nickname.isNotEmpty) 'nickname': nickname,
    if (pinned) 'pinned': pinned,
    if (sortOrder != 0) 'sortOrder': sortOrder,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };

  factory BambuCloudAccount.fromJson(Map<String, dynamic> json) {
    final regionCode = json['region'] as String? ?? 'China';
    final lastUsedAtStr = json['lastUsedAt'] as String?;
    return BambuCloudAccount(
      region: regionCode == 'Overseas'
          ? BambuRegion.overseas
          : BambuRegion.china,
      email: json['email'] as String,
      password: json['password'] as String,
      nickname: json['nickname'] as String? ?? '',
      pinned: json['pinned'] as bool? ?? false,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      lastUsedAt: lastUsedAtStr != null
          ? DateTime.tryParse(lastUsedAtStr)
          : null,
    );
  }
}
