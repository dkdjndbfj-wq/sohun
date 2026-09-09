import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/friendly_error.dart';
import '../../../data/models/app_auth.dart';
import '../../../data/prefs/app_prefs.dart';
import '../../../providers/app_auth_provider.dart';
import '../../../providers/studio_provider.dart';
import 'farm_components.dart';
import 'farm_feedback.dart';

Future<void> showAppAccountRegistrationFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final payload = await _showOwnerRegistrationDialog(context);
  if (payload == null || !context.mounted) return;
  try {
    final result = await ref.read(appAuthProvider.notifier).register(
          AppRegisterRequest(
            email: payload.email,
            handle: payload.handle,
            displayName: payload.displayName,
            password: payload.password,
            acceptTerms: payload.acceptTerms,
          ),
        );
    if (!context.mounted) return;
    showSnack(
      context,
      result.verificationRequired ? '软件账号已创建，请先完成邮箱验证' : '软件账号已创建并登录',
    );
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showFarmOwnerLoginFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final payload = await _showOwnerLoginDialog(context);
  if (payload == null || !context.mounted) return;
  try {
    final session = await ref.read(appAuthProvider.notifier).login(
          AppLoginRequest(email: payload.email, password: payload.password),
        );
    if (session.user.emailVerified) {
      final hasFarm =
          await ref.read(studioCloudServiceProvider).hasOwnedFarmOrganization();
      if (!hasFarm) {
        await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
        if (context.mounted) {
          showSnack(context, '软件账号已登录，请继续开通农场管理员身份');
        }
        return;
      }
    }
    await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
    if (context.mounted) showSnack(context, '农场管理员账号已登录');
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showDirectFarmOwnerRegistrationFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final payload = await _showOwnerRegistrationDialog(context);
  if (payload == null || !context.mounted) return;
  try {
    final result = await ref.read(appAuthProvider.notifier).register(
          AppRegisterRequest(
            email: payload.email,
            handle: payload.handle,
            displayName: payload.displayName,
            password: payload.password,
            acceptTerms: payload.acceptTerms,
          ),
        );
    await ref.read(studioCloudServiceProvider).registerFarmOrganization();
    await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
    if (!context.mounted) return;
    if (result.verificationRequired) {
      showSnack(context, '软件账号和农场申请已创建，请先完成邮箱验证');
      return;
    }
    showSnack(context, '软件账号和农场申请已创建，请继续填写农场资料');
    await showFarmOnboardingFlow(context, ref);
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showFarmStaffLoginFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final payload = await _showStaffLoginDialog(context);
  if (payload == null || !context.mounted) return;
  try {
    final notifier = ref.read(appAuthProvider.notifier);
    final session = await notifier.loginFarmStaff(
      FarmStaffLoginRequest(
        organizationCode: payload.organizationCode,
        loginName: payload.loginName,
        password: payload.password,
      ),
    );
    await ref.read(studioModeEnabledProvider.notifier).setEnabled(true);
    if (!context.mounted) return;
    showSnack(context, '已登录 ${session.farmOrganizationName ?? '打印农场'}');
    if (!session.mustChangePassword) return;
    final changed = await _showPasswordChangeDialog(
      context,
      initialCurrentPassword: payload.password,
      barrierDismissible: false,
    );
    if (changed == null) {
      await notifier.logout();
      if (context.mounted) {
        showSnack(context, '必须修改初始密码后才能使用农场功能', error: true);
      }
      return;
    }
    await notifier.changeFarmInitialPassword(
      FarmInitialPasswordChangeRequest(
        currentPassword: changed.currentPassword,
        newPassword: changed.newPassword,
      ),
    );
    if (context.mounted) showSnack(context, '初始密码已修改，成员账号可以正常使用');
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showFarmStaffPasswordChangeFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final changed = await _showPasswordChangeDialog(context);
  if (changed == null || !context.mounted) return;
  try {
    await ref.read(appAuthProvider.notifier).changeFarmInitialPassword(
          FarmInitialPasswordChangeRequest(
            currentPassword: changed.currentPassword,
            newPassword: changed.newPassword,
          ),
        );
    if (context.mounted) showSnack(context, '农场成员密码已修改');
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showFarmEmailVerificationFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  final code = await _showEmailVerificationDialog(context, ref);
  if (code == null || !context.mounted) return;
  try {
    await ref.read(appAuthProvider.notifier).confirmEmailVerification(code);
    if (context.mounted) showSnack(context, '邮箱验证成功');
  } catch (error) {
    if (context.mounted) showSnack(context, friendlyError(error), error: true);
  }
}

Future<void> showFarmAccountLogoutFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  try {
    await ref.read(appAuthProvider.notifier).logout();
    if (context.mounted) showSnack(context, '已退出 sohun 账号');
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '本机会话已清除；${friendlyError(error)}', error: true);
    }
  }
}

Future<void> showFarmOnboardingFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  Map<String, dynamic> payload;
  try {
    payload =
        await ref.read(studioCloudServiceProvider).getFarmOrganizationProfile();
  } catch (error) {
    if (context.mounted) {
      showSnack(context, '读取农场入驻资料失败：$error', error: true);
    }
    return;
  }
  if (!context.mounted) return;
  final organization = payload['organization'] is Map
      ? Map<String, dynamic>.from(payload['organization'] as Map)
      : <String, dynamic>{};
  String text(String key) => organization[key]?.toString() ?? '';
  String joined(String key) =>
      organization[key] is List ? (organization[key] as List).join('、') : '';
  final displayName = TextEditingController(text: text('displayName'));
  final legalName = TextEditingController(text: text('legalName'));
  final registrationNumber =
      TextEditingController(text: text('registrationNumber'));
  final contactName = TextEditingController(text: text('contactName'));
  final contactPhone = TextEditingController(text: text('contactPhone'));
  final contactEmail = TextEditingController(text: text('contactEmail'));
  final region = TextEditingController(text: text('region'));
  final businessAddress = TextEditingController(text: text('businessAddress'));
  final serviceArea = TextEditingController(text: text('serviceArea'));
  final printerCount = TextEditingController(
    text: text('printerCount').isEmpty ? '0' : text('printerCount'),
  );
  final staffCount = TextEditingController(
    text: text('staffCount').isEmpty ? '0' : text('staffCount'),
  );
  final locationCount = TextEditingController(
    text: text('locationCount').isEmpty ? '1' : text('locationCount'),
  );
  final printerModels = TextEditingController(text: joined('printerModels'));
  final materials = TextEditingController(text: joined('materials'));
  final orderTypes = TextEditingController(text: joined('orderTypes'));
  var subjectType =
      text('subjectType').isEmpty ? 'unregistered_studio' : text('subjectType');
  var invoiceCapability = organization['invoiceCapability'] == true;
  var saving = false;
  StateSetter? updateDialog;

  List<String> splitList(String value) => value
      .split(RegExp(r'[,，、\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> save({required bool submit}) async {
    if (saving) return;
    updateDialog?.call(() => saving = true);
    try {
      await ref.read(studioCloudServiceProvider).saveFarmOrganizationProfile(
        {
          'displayName': displayName.text.trim(),
          'legalName': legalName.text.trim(),
          'subjectType': subjectType,
          'registrationNumber': registrationNumber.text.trim(),
          'contactName': contactName.text.trim(),
          'contactPhone': contactPhone.text.trim(),
          'contactEmail': contactEmail.text.trim(),
          'region': region.text.trim(),
          'businessAddress': businessAddress.text.trim(),
          'serviceArea': serviceArea.text.trim(),
          'printerCount': int.tryParse(printerCount.text.trim()) ?? 0,
          'staffCount': int.tryParse(staffCount.text.trim()) ?? 0,
          'locationCount': int.tryParse(locationCount.text.trim()) ?? 1,
          'printerModels': splitList(printerModels.text),
          'materials': splitList(materials.text),
          'orderTypes': splitList(orderTypes.text),
          'invoiceCapability': invoiceCapability,
        },
        submitForVerification: submit,
      );
      if (!context.mounted) return;
      Navigator.of(context).pop();
      showSnack(context, submit ? '农场资料已提交审核' : '农场资料草稿已保存');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, '${submit ? '提交' : '保存'}失败：$error', error: true);
        updateDialog?.call(() => saving = false);
      }
    }
  }

  await AppDialog.show<void>(
    context: context,
    title: '农场主体与入驻认证',
    barrierDismissible: !saving,
    content: StatefulBuilder(
      builder: (dialogContext, setState) {
        updateDialog = setState;
        return Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '农场编号：${text('organizationCode')} · 当前状态：${_verificationLabel(text('verificationStatus'))}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            AppInput(label: '农场展示名称', controller: displayName),
            const SizedBox(height: 12),
            AppSelect<String>(
              value: subjectType,
              label: '经营主体类型',
              items: const [
                DropdownMenuItem(value: 'company', child: Text('企业')),
                DropdownMenuItem(
                    value: 'sole_proprietor', child: Text('个体工商户')),
                DropdownMenuItem(value: 'studio', child: Text('工作室')),
                DropdownMenuItem(
                    value: 'individual_operator', child: Text('个人经营者')),
                DropdownMenuItem(
                    value: 'unregistered_studio', child: Text('未注册工作室')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => subjectType = value);
              },
            ),
            const SizedBox(height: 12),
            AppInput(label: '主体法定名称', controller: legalName),
            const SizedBox(height: 12),
            AppInput(
              label: '统一社会信用代码 / 登记编号',
              controller: registrationNumber,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                    child: AppInput(label: '负责人姓名', controller: contactName)),
                const SizedBox(width: 10),
                Expanded(
                    child: AppInput(label: '负责人电话', controller: contactPhone)),
              ],
            ),
            const SizedBox(height: 12),
            AppInput(label: '负责人邮箱', controller: contactEmail),
            const SizedBox(height: 12),
            AppInput(label: '经营地区', controller: region),
            const SizedBox(height: 12),
            AppInput(label: '经营地址', controller: businessAddress),
            const SizedBox(height: 12),
            AppInput(label: '服务区域', controller: serviceArea),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppInput(
                    label: '打印机数量',
                    controller: printerCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '成员数量',
                    controller: staffCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppInput(
                    label: '生产地点',
                    controller: locationCount,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppInput(label: '主要打印机型号（用顿号分隔）', controller: printerModels),
            const SizedBox(height: 12),
            AppInput(label: '主要材料（用顿号分隔）', controller: materials),
            const SizedBox(height: 12),
            AppInput(label: '主要接单类型（用顿号分隔）', controller: orderTypes),
            const SizedBox(height: 6),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('支持开票'),
              value: invoiceCapability,
              onChanged: saving
                  ? null
                  : (value) => setState(() => invoiceCapability = value),
            ),
            const Text(
              '银行、结算和身份证明等敏感资料仅在启用对应能力时按需补充。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: saving ? null : () => save(submit: false),
        child: const Text('保存草稿'),
      ),
      FilledButton(
        onPressed: saving ? null : () => save(submit: true),
        child: Text(saving ? '提交中...' : '提交审核'),
      ),
    ],
  );

  for (final controller in [
    displayName,
    legalName,
    registrationNumber,
    contactName,
    contactPhone,
    contactEmail,
    region,
    businessAddress,
    serviceArea,
    printerCount,
    staffCount,
    locationCount,
    printerModels,
    materials,
    orderTypes,
  ]) {
    controller.dispose();
  }
}

Future<_OwnerLoginPayload?> _showOwnerLoginDialog(BuildContext context) async {
  final email = TextEditingController();
  final password = TextEditingController();
  final result = await AppDialog.show<_OwnerLoginPayload>(
    context: context,
    title: '农场管理员登录',
    content: Column(
      children: [
        AppInput(label: '软件账号邮箱', controller: email),
        const SizedBox(height: 12),
        AppInput(label: '密码', controller: password, obscureText: true),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.of(context).pop(
          _OwnerLoginPayload(email.text, password.text),
        ),
        icon: const Icon(Icons.login_rounded, size: 17),
        label: const Text('登录'),
      ),
    ],
  );
  email.dispose();
  password.dispose();
  return result;
}

Future<_OwnerRegistrationPayload?> _showOwnerRegistrationDialog(
  BuildContext context,
) async {
  final email = TextEditingController();
  final handle = TextEditingController();
  final displayName = TextEditingController();
  final password = TextEditingController();
  var accepted = false;
  final result = await AppDialog.show<_OwnerRegistrationPayload>(
    context: context,
    title: '开通农场管理员账号',
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          AppInput(label: '邮箱', controller: email),
          const SizedBox(height: 12),
          AppInput(label: '用户名', controller: handle, hint: '小写字母、数字或下划线'),
          const SizedBox(height: 12),
          AppInput(label: '显示名称', controller: displayName),
          const SizedBox(height: 12),
          AppInput(label: '密码', controller: password, obscureText: true),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: accepted,
            onChanged: (value) => setState(() => accepted = value ?? false),
            title: const Text('同意服务条款和隐私政策'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.of(context).pop(
          _OwnerRegistrationPayload(
            email: email.text,
            handle: handle.text,
            displayName: displayName.text,
            password: password.text,
            acceptTerms: accepted,
          ),
        ),
        icon: const Icon(Icons.add_business_outlined, size: 17),
        label: const Text('创建并开通'),
      ),
    ],
  );
  email.dispose();
  handle.dispose();
  displayName.dispose();
  password.dispose();
  return result;
}

Future<_StaffLoginPayload?> _showStaffLoginDialog(BuildContext context) async {
  final code = TextEditingController();
  final loginName = TextEditingController();
  final password = TextEditingController();
  final result = await AppDialog.show<_StaffLoginPayload>(
    context: context,
    title: '农场成员登录',
    content: Column(
      children: [
        AppInput(label: '农场编号', controller: code),
        const SizedBox(height: 12),
        AppInput(label: '成员登录名', controller: loginName),
        const SizedBox(height: 12),
        AppInput(label: '密码', controller: password, obscureText: true),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.of(context).pop(
          _StaffLoginPayload(code.text, loginName.text, password.text),
        ),
        icon: const Icon(Icons.badge_outlined, size: 17),
        label: const Text('登录'),
      ),
    ],
  );
  code.dispose();
  loginName.dispose();
  password.dispose();
  return result;
}

Future<_PasswordPayload?> _showPasswordChangeDialog(
  BuildContext context, {
  String? initialCurrentPassword,
  bool barrierDismissible = true,
}) async {
  final current = TextEditingController(text: initialCurrentPassword);
  final next = TextEditingController();
  final confirm = TextEditingController();
  final result = await AppDialog.show<_PasswordPayload>(
    context: context,
    title: '修改成员密码',
    barrierDismissible: barrierDismissible,
    content: Column(
      children: [
        AppInput(label: '当前密码', controller: current, obscureText: true),
        const SizedBox(height: 12),
        AppInput(
          label: '新密码',
          hint: '至少 12 位并包含符号',
          controller: next,
          obscureText: true,
        ),
        const SizedBox(height: 12),
        AppInput(label: '确认新密码', controller: confirm, obscureText: true),
      ],
    ),
    actions: [
      if (barrierDismissible)
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      FilledButton(
        onPressed: () {
          if (next.text != confirm.text) {
            showSnack(context, '两次输入的新密码不一致', error: true);
            return;
          }
          Navigator.of(context).pop(_PasswordPayload(current.text, next.text));
        },
        child: const Text('保存新密码'),
      ),
    ],
  );
  current.dispose();
  next.dispose();
  confirm.dispose();
  return result;
}

Future<String?> _showEmailVerificationDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final code = TextEditingController();
  final result = await AppDialog.show<String>(
    context: context,
    title: '验证管理员邮箱',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('请输入邮箱中收到的验证码。'),
        const SizedBox(height: 12),
        AppInput(label: '验证码', controller: code),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              try {
                await ref
                    .read(appAuthProvider.notifier)
                    .requestEmailVerification();
                if (context.mounted) showSnack(context, '验证码已重新发送');
              } catch (error) {
                if (context.mounted) {
                  showSnack(context, friendlyError(error), error: true);
                }
              }
            },
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('重新发送'),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(code.text.trim()),
        child: const Text('完成验证'),
      ),
    ],
  );
  code.dispose();
  return result;
}

String _verificationLabel(String status) => switch (status) {
      'draft' => '草稿',
      'pending_submission' => '待重新提交',
      'under_review' => '审核中',
      'needs_information' => '需要补充资料',
      'verified' => '已认证',
      'rejected' => '未通过',
      'suspended' => '已暂停',
      _ => '未开始',
    };

class _OwnerLoginPayload {
  const _OwnerLoginPayload(this.email, this.password);

  final String email;
  final String password;
}

class _OwnerRegistrationPayload {
  const _OwnerRegistrationPayload({
    required this.email,
    required this.handle,
    required this.displayName,
    required this.password,
    required this.acceptTerms,
  });

  final String email;
  final String handle;
  final String displayName;
  final String password;
  final bool acceptTerms;
}

class _StaffLoginPayload {
  const _StaffLoginPayload(
    this.organizationCode,
    this.loginName,
    this.password,
  );

  final String organizationCode;
  final String loginName;
  final String password;
}

class _PasswordPayload {
  const _PasswordPayload(this.currentPassword, this.newPassword);

  final String currentPassword;
  final String newPassword;
}
