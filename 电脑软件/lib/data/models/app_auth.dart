/// Identity used by the consumable workbench's own service.
///
/// This identity is independent from Bambu Cloud accounts and is the sole
/// author identity used for sohun community publishing.
class AppUser {
  final String id;
  final String email;
  final String handle;
  final String displayName;
  final String? avatarUrl;
  final String? bio;
  final bool emailVerified;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AppUser({
    required this.id,
    required this.email,
    required this.handle,
    required this.displayName,
    this.avatarUrl,
    this.bio,
    required this.emailVerified,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final createdAt = _requiredDate(json, const ['created_at', 'createdAt']);
    return AppUser(
      id: _requiredString(json, const ['id']),
      email: _requiredString(json, const ['email']).toLowerCase(),
      handle: _requiredString(json, const ['handle']).toLowerCase(),
      displayName: _requiredString(json, const ['display_name', 'displayName']),
      avatarUrl: _optionalString(json, const ['avatar_url', 'avatarUrl']),
      bio: _optionalString(json, const ['bio']),
      emailVerified: _requiredBool(
        json,
        const ['email_verified', 'emailVerified'],
      ),
      createdAt: createdAt,
      updatedAt:
          _optionalDate(json, const ['updated_at', 'updatedAt']) ?? createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'handle': handle,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'bio': bio,
        'emailVerified': emailVerified,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  AppUser copyWith({
    String? id,
    String? email,
    String? handle,
    String? displayName,
    String? avatarUrl,
    String? bio,
    bool? emailVerified,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AppUser(
      id: id ?? this.id,
      email: email ?? this.email,
      handle: handle ?? this.handle,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      emailVerified: emailVerified ?? this.emailVerified,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Authenticated session issued by the workbench's own service.
///
/// [serverBaseUrl] binds credentials to the server that issued them so a
/// runtime endpoint change can never send a token to another host.
class AppAuthSession {
  final AppUser user;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final DateTime? refreshExpiresAt;
  final String serverBaseUrl;
  final String authRealm;
  final String? farmOrganizationId;
  final String? farmOrganizationCode;
  final String? farmOrganizationName;
  final String? farmStaffMemberId;
  final String? farmStaffLoginName;
  final String? farmStaffRoleCode;
  final List<String> farmStaffRoleCodes;
  final bool mustChangePassword;

  const AppAuthSession({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.refreshExpiresAt,
    required this.serverBaseUrl,
    this.authRealm = 'personal',
    this.farmOrganizationId,
    this.farmOrganizationCode,
    this.farmOrganizationName,
    this.farmStaffMemberId,
    this.farmStaffLoginName,
    this.farmStaffRoleCode,
    this.farmStaffRoleCodes = const [],
    this.mustChangePassword = false,
  });

  factory AppAuthSession.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    if (rawUser is! Map) {
      throw const FormatException('认证会话缺少 user 对象');
    }
    return AppAuthSession(
      user: AppUser.fromJson(Map<String, dynamic>.from(rawUser)),
      accessToken: _requiredString(json, const ['access_token', 'accessToken']),
      refreshToken:
          _requiredString(json, const ['refresh_token', 'refreshToken']),
      expiresAt: _requiredDate(json, const ['expires_at', 'expiresAt']),
      refreshExpiresAt: _optionalDate(
        json,
        const ['refresh_expires_at', 'refreshExpiresAt'],
      ),
      serverBaseUrl: _requiredString(
        json,
        const ['server_base_url', 'serverBaseUrl'],
      ),
      authRealm: _optionalString(json, const ['auth_realm', 'authRealm']) ??
          'personal',
      farmOrganizationId: _optionalString(
        json,
        const ['farm_organization_id', 'farmOrganizationId'],
      ),
      farmOrganizationCode: _optionalString(
        json,
        const ['farm_organization_code', 'farmOrganizationCode'],
      ),
      farmOrganizationName: _optionalString(
        json,
        const ['farm_organization_name', 'farmOrganizationName'],
      ),
      farmStaffMemberId: _optionalString(
        json,
        const ['farm_staff_member_id', 'farmStaffMemberId'],
      ),
      farmStaffLoginName: _optionalString(
        json,
        const ['farm_staff_login_name', 'farmStaffLoginName'],
      ),
      farmStaffRoleCode: _optionalString(
        json,
        const ['farm_staff_role_code', 'farmStaffRoleCode'],
      ),
      farmStaffRoleCodes: _optionalStringList(
        json,
        const ['farm_staff_role_codes', 'farmStaffRoleCodes'],
      ),
      mustChangePassword: _optionalBool(
            json,
            const ['must_change_password', 'mustChangePassword'],
          ) ??
          false,
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user.toJson(),
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        if (refreshExpiresAt != null)
          'refreshExpiresAt': refreshExpiresAt!.toUtc().toIso8601String(),
        'serverBaseUrl': serverBaseUrl,
        'authRealm': authRealm,
        if (farmOrganizationId != null)
          'farmOrganizationId': farmOrganizationId,
        if (farmOrganizationCode != null)
          'farmOrganizationCode': farmOrganizationCode,
        if (farmOrganizationName != null)
          'farmOrganizationName': farmOrganizationName,
        if (farmStaffMemberId != null) 'farmStaffMemberId': farmStaffMemberId,
        if (farmStaffLoginName != null)
          'farmStaffLoginName': farmStaffLoginName,
        if (farmStaffRoleCode != null) 'farmStaffRoleCode': farmStaffRoleCode,
        'farmStaffRoleCodes': farmStaffRoleCodes,
        'mustChangePassword': mustChangePassword,
      };

  bool isAccessTokenExpired({
    DateTime? now,
    Duration clockSkew = const Duration(seconds: 30),
  }) {
    final current = now ?? DateTime.now();
    return !current.add(clockSkew).isBefore(expiresAt);
  }

  bool isRefreshTokenExpired({DateTime? now}) {
    final expiry = refreshExpiresAt;
    if (expiry == null) return false;
    return !(now ?? DateTime.now()).isBefore(expiry);
  }

  AppAuthSession copyWith({
    AppUser? user,
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    DateTime? refreshExpiresAt,
    String? serverBaseUrl,
    String? authRealm,
    String? farmOrganizationId,
    String? farmOrganizationCode,
    String? farmOrganizationName,
    String? farmStaffMemberId,
    String? farmStaffLoginName,
    String? farmStaffRoleCode,
    List<String>? farmStaffRoleCodes,
    bool? mustChangePassword,
  }) {
    return AppAuthSession(
      user: user ?? this.user,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      refreshExpiresAt: refreshExpiresAt ?? this.refreshExpiresAt,
      serverBaseUrl: serverBaseUrl ?? this.serverBaseUrl,
      authRealm: authRealm ?? this.authRealm,
      farmOrganizationId: farmOrganizationId ?? this.farmOrganizationId,
      farmOrganizationCode: farmOrganizationCode ?? this.farmOrganizationCode,
      farmOrganizationName: farmOrganizationName ?? this.farmOrganizationName,
      farmStaffMemberId: farmStaffMemberId ?? this.farmStaffMemberId,
      farmStaffLoginName: farmStaffLoginName ?? this.farmStaffLoginName,
      farmStaffRoleCode: farmStaffRoleCode ?? this.farmStaffRoleCode,
      farmStaffRoleCodes: farmStaffRoleCodes ?? this.farmStaffRoleCodes,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    );
  }
}

/// Registration payload. Password is only exposed through [toJson] for the
/// outbound request and is never part of a persisted model.
class AppAccountAgreement {
  AppAccountAgreement._();

  /// Increment these values whenever the corresponding published document
  /// changes materially. The server records both versions with the acceptance
  /// timestamp so registration consent is auditable without storing extra
  /// client data.
  static const termsVersion = '2026-07-29';
  static const privacyVersion = '2026-07-29';
}

enum AppAccountPolicyType {
  terms('terms', '服务条款'),
  privacy('privacy', '隐私政策');

  final String pathSegment;
  final String label;

  const AppAccountPolicyType(this.pathSegment, this.label);
}

class AppAccountPolicyDocument {
  final AppAccountPolicyType type;
  final String version;
  final bool isCurrent;
  final String title;
  final DateTime effectiveAt;
  final String content;

  const AppAccountPolicyDocument({
    required this.type,
    required this.version,
    required this.isCurrent,
    required this.title,
    required this.effectiveAt,
    required this.content,
  });

  factory AppAccountPolicyDocument.fromJson(Map<String, dynamic> json) {
    final typeText = _requiredString(json, const ['type']);
    final type = AppAccountPolicyType.values
        .where((candidate) => candidate.pathSegment == typeText)
        .firstOrNull;
    if (type == null) throw const FormatException('政策类型不受支持');
    return AppAccountPolicyDocument(
      type: type,
      version: _requiredString(json, const ['version']),
      isCurrent: _requiredBool(json, const ['current']),
      title: _requiredString(json, const ['title']),
      effectiveAt: _requiredDate(json, const ['effectiveAt']),
      content: _requiredString(json, const ['content']),
    );
  }
}

class AppRegisterRequest {
  final String email;
  final String handle;
  final String displayName;
  final String password;
  final bool acceptTerms;
  final String termsVersion;
  final String privacyVersion;

  factory AppRegisterRequest({
    required String email,
    required String handle,
    required String displayName,
    required String password,
    required bool acceptTerms,
    String termsVersion = AppAccountAgreement.termsVersion,
    String privacyVersion = AppAccountAgreement.privacyVersion,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    final normalizedHandle = handle.trim().toLowerCase();
    final normalizedDisplayName = displayName.trim();
    if (!_emailPattern.hasMatch(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', '邮箱格式不正确');
    }
    if (!_handlePattern.hasMatch(normalizedHandle)) {
      throw ArgumentError.value(
        handle,
        'handle',
        '用户名须为 3-30 位小写字母、数字、点、下划线或短横线',
      );
    }
    if (normalizedDisplayName.isEmpty || normalizedDisplayName.length > 40) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        '显示名须为 1-40 个字符',
      );
    }
    _validatePassword(password);
    if (!acceptTerms) {
      throw ArgumentError.value(
        acceptTerms,
        'acceptTerms',
        '请先同意服务条款和隐私政策',
      );
    }
    final normalizedTermsVersion = termsVersion.trim();
    final normalizedPrivacyVersion = privacyVersion.trim();
    if (normalizedTermsVersion.isEmpty || normalizedPrivacyVersion.isEmpty) {
      throw ArgumentError('服务条款和隐私政策版本不能为空');
    }
    return AppRegisterRequest._(
      email: normalizedEmail,
      handle: normalizedHandle,
      displayName: normalizedDisplayName,
      password: password,
      acceptTerms: acceptTerms,
      termsVersion: normalizedTermsVersion,
      privacyVersion: normalizedPrivacyVersion,
    );
  }

  const AppRegisterRequest._({
    required this.email,
    required this.handle,
    required this.displayName,
    required this.password,
    required this.acceptTerms,
    required this.termsVersion,
    required this.privacyVersion,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'handle': handle,
        'displayName': displayName,
        'password': password,
        'acceptTerms': acceptTerms,
        'termsVersion': termsVersion,
        'privacyVersion': privacyVersion,
      };
}

/// Login payload for the application's own account service.
class AppLoginRequest {
  final String email;
  final String password;

  factory AppLoginRequest({
    required String email,
    required String password,
  }) {
    final normalized = email.trim().toLowerCase();
    if (!_emailPattern.hasMatch(normalized)) {
      throw ArgumentError.value(email, 'email', '邮箱格式不正确');
    }
    if (password.isEmpty) {
      throw ArgumentError.value('', 'password', '密码不能为空');
    }
    return AppLoginRequest._(email: normalized, password: password);
  }

  const AppLoginRequest._({
    required this.email,
    required this.password,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'password': password,
      };
}

class FarmStaffLoginRequest {
  final String organizationCode;
  final String loginName;
  final String password;

  factory FarmStaffLoginRequest({
    required String organizationCode,
    required String loginName,
    required String password,
  }) {
    final normalizedCode = organizationCode.trim().toUpperCase();
    final normalizedLogin = loginName.trim().toLowerCase();
    if (normalizedCode.length < 4 || normalizedCode.length > 32) {
      throw ArgumentError.value(
        organizationCode,
        'organizationCode',
        '农场编号格式不正确',
      );
    }
    if (!_handlePattern.hasMatch(normalizedLogin)) {
      throw ArgumentError.value(loginName, 'loginName', '员工登录名格式不正确');
    }
    if (password.isEmpty) {
      throw ArgumentError.value('', 'password', '密码不能为空');
    }
    return FarmStaffLoginRequest._(
      organizationCode: normalizedCode,
      loginName: normalizedLogin,
      password: password,
    );
  }

  const FarmStaffLoginRequest._({
    required this.organizationCode,
    required this.loginName,
    required this.password,
  });

  Map<String, dynamic> toJson() => {
        'organizationCode': organizationCode,
        'loginName': loginName,
        'password': password,
      };
}

class FarmInitialPasswordChangeRequest {
  final String currentPassword;
  final String newPassword;

  factory FarmInitialPasswordChangeRequest({
    required String currentPassword,
    required String newPassword,
  }) {
    if (currentPassword.isEmpty) {
      throw ArgumentError.value('', 'currentPassword', '当前密码不能为空');
    }
    _validatePassword(newPassword);
    if (newPassword.length < 12) {
      throw ArgumentError.value(
        newPassword.length,
        'newPassword',
        '农场员工密码至少 12 位',
      );
    }
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(newPassword)) {
      throw ArgumentError.value(newPassword, 'newPassword', '新密码还必须包含符号');
    }
    return FarmInitialPasswordChangeRequest._(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  const FarmInitialPasswordChangeRequest._({
    required this.currentPassword,
    required this.newPassword,
  });

  Map<String, dynamic> toJson() => {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      };
}

class AppPasswordResetRequest {
  final String email;

  factory AppPasswordResetRequest(String email) {
    final normalized = email.trim().toLowerCase();
    if (!_emailPattern.hasMatch(normalized)) {
      throw ArgumentError.value(email, 'email', '邮箱格式不正确');
    }
    return AppPasswordResetRequest._(normalized);
  }

  const AppPasswordResetRequest._(this.email);

  Map<String, dynamic> toJson() => {'email': email};
}

class AppPasswordResetConfirmation {
  final String email;
  final String code;
  final String newPassword;

  factory AppPasswordResetConfirmation({
    required String email,
    required String code,
    required String newPassword,
  }) {
    final request = AppPasswordResetRequest(email);
    final normalizedCode = code.trim();
    if (!RegExp(r'^\d{8}$').hasMatch(normalizedCode)) {
      throw ArgumentError.value(code, 'code', '验证码必须为 8 位数字');
    }
    _validatePassword(newPassword);
    return AppPasswordResetConfirmation._(
      email: request.email,
      code: normalizedCode,
      newPassword: newPassword,
    );
  }

  const AppPasswordResetConfirmation._({
    required this.email,
    required this.code,
    required this.newPassword,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'code': code,
        'newPassword': newPassword,
      };
}

class AppAccountDeletionRequest {
  final String password;

  factory AppAccountDeletionRequest(String password) {
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', '密码不能为空');
    }
    return AppAccountDeletionRequest._(password);
  }

  const AppAccountDeletionRequest._(this.password);

  Map<String, dynamic> toJson() => {
        'password': password,
        'confirmation': 'DELETE',
      };
}

/// Editable public fields for `PATCH /v1/me`.
class AppUserUpdateRequest {
  final String? handle;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;

  factory AppUserUpdateRequest({
    String? handle,
    String? displayName,
    String? avatarUrl,
    String? bio,
  }) {
    final normalizedHandle = handle?.trim().toLowerCase();
    final normalizedDisplayName = displayName?.trim();
    final normalizedAvatarUrl = avatarUrl?.trim();
    final normalizedBio = bio?.trim();
    if (normalizedHandle != null &&
        !_handlePattern.hasMatch(normalizedHandle)) {
      throw ArgumentError.value(
        handle,
        'handle',
        '用户名须为 3-24 位小写字母、数字或下划线',
      );
    }
    if (normalizedDisplayName != null &&
        (normalizedDisplayName.isEmpty || normalizedDisplayName.length > 40)) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        '显示名须为 1-40 个字符',
      );
    }
    if (normalizedBio != null && normalizedBio.length > 300) {
      throw ArgumentError.value(bio, 'bio', '个人简介最多 300 个字符');
    }
    if (normalizedHandle == null &&
        normalizedDisplayName == null &&
        normalizedAvatarUrl == null &&
        normalizedBio == null) {
      throw ArgumentError('至少需要修改一项用户资料');
    }
    return AppUserUpdateRequest._(
      handle: normalizedHandle,
      displayName: normalizedDisplayName,
      avatarUrl: normalizedAvatarUrl,
      bio: normalizedBio,
    );
  }

  const AppUserUpdateRequest._({
    this.handle,
    this.displayName,
    this.avatarUrl,
    this.bio,
  });

  Map<String, dynamic> toJson() => {
        if (handle != null) 'handle': handle,
        if (displayName != null) 'displayName': displayName,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        if (bio != null) 'bio': bio,
      };
}

class AppRegistrationResult {
  final AppUser user;
  final AppAuthSession session;
  final bool verificationRequired;
  final bool verificationEmailSent;

  const AppRegistrationResult({
    required this.user,
    required this.session,
    required this.verificationRequired,
    this.verificationEmailSent = false,
  });
}

void _validatePassword(String password) {
  if (password.length < 10 || password.length > 128) {
    throw ArgumentError.value(
      password.length,
      'password',
      '密码须为 10-128 个字符',
    );
  }
  if (!RegExp(r'[a-z]').hasMatch(password) ||
      !RegExp(r'[A-Z]').hasMatch(password) ||
      !RegExp(r'\d').hasMatch(password)) {
    throw ArgumentError.value(
      password,
      'password',
      '密码至少包含大写字母、小写字母和数字',
    );
  }
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final _handlePattern = RegExp(r'^[a-z0-9][a-z0-9_.-]{2,29}$');

String _requiredString(Map<String, dynamic> json, List<String> keys) {
  final value = _valueForKeys(json, keys);
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('字段 ${keys.first} 缺失或格式错误');
  }
  return value.trim();
}

String? _optionalString(Map<String, dynamic> json, List<String> keys) {
  final value = _valueForKeys(json, keys);
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('字段 ${keys.first} 格式错误');
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _optionalStringList(
  Map<String, dynamic> json,
  List<String> keys,
) {
  final value = _valueForKeys(json, keys);
  if (value == null) return const [];
  if (value is! List) {
    throw FormatException('字段 ${keys.first} 格式错误');
  }
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

bool _requiredBool(Map<String, dynamic> json, List<String> keys) {
  final value = _valueForKeys(json, keys);
  if (value is bool) return value;
  throw FormatException('字段 ${keys.first} 缺失或格式错误');
}

bool? _optionalBool(Map<String, dynamic> json, List<String> keys) {
  final value = _valueForKeys(json, keys);
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('字段 ${keys.first} 格式错误');
}

DateTime _requiredDate(Map<String, dynamic> json, List<String> keys) {
  final parsed = _parseDate(_valueForKeys(json, keys));
  if (parsed == null) {
    throw FormatException('字段 ${keys.first} 缺失或格式错误');
  }
  return parsed;
}

DateTime? _optionalDate(Map<String, dynamic> json, List<String> keys) {
  final value = _valueForKeys(json, keys);
  if (value == null) return null;
  final parsed = _parseDate(value);
  if (parsed == null) throw FormatException('字段 ${keys.first} 格式错误');
  return parsed;
}

dynamic _valueForKeys(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

DateTime? _parseDate(dynamic value) {
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  if (value is num) {
    final milliseconds =
        value > 100000000000 ? value.toInt() : value.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  }
  return null;
}
