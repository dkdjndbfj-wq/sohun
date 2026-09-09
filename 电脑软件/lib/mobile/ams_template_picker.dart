import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/color_utils.dart';
import '../widgets/filament_spool_icon.dart';
import 'ams_tag_template.dart';
import 'ams_template_repository.dart';
import 'mobile_glass_choice_chip.dart';

class AmsTemplateChoice {
  const AmsTemplateChoice.saved(this.template) : readFromTag = false;
  const AmsTemplateChoice.read() : template = null, readFromTag = true;
  final AmsTagTemplate? template;
  final bool readFromTag;
}

/// Templates and their authentication keys remain on this device. This sheet
/// deliberately has no inventory/cloud service dependency.
Future<AmsTemplateChoice?> showAmsTemplatePicker(
  BuildContext context, {
  required AmsTemplateRepository repository,
  required String ownerAccount,
  required ValueListenable<int> accountRevision,
  void Function(String id)? onDeleted,
}) => showModalBottomSheet<AmsTemplateChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _TemplateSheet(
    repository: repository,
    ownerAccount: ownerAccount,
    accountRevision: accountRevision,
    onDeleted: onDeleted,
  ),
);

class _TemplateSheet extends StatefulWidget {
  const _TemplateSheet({
    required this.repository,
    required this.ownerAccount,
    required this.accountRevision,
    this.onDeleted,
  });
  final AmsTemplateRepository repository;
  final String ownerAccount;
  final ValueListenable<int> accountRevision;
  final void Function(String id)? onDeleted;
  @override
  State<_TemplateSheet> createState() => _TemplateSheetState();
}

class _TemplateSheetState extends State<_TemplateSheet> {
  List<AmsTagTemplate> _templates = [];
  bool _busy = true;
  String? _error;
  late final int _openedRevision;
  bool get _currentAccount => widget.accountRevision.value == _openedRevision;

  @override
  void initState() {
    super.initState();
    _openedRevision = widget.accountRevision.value;
    widget.accountRevision.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    if (_currentAccount) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.accountRevision.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_currentAccount) return;
    try {
      final templates = await widget.repository.list(
        ownerAccount: widget.ownerAccount,
      );
      if (mounted && _currentAccount) {
        setState(() {
          _templates = templates;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本机模板库暂不可用，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (!_currentAccount) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '完整标签模板',
            extensions: ['bin', 'mfd', 'dump', 'txt', 'mct', 'json'],
          ),
        ],
      );
      if (file == null || !mounted || !_currentAccount) return;
      if (await file.length() > 65536) throw const FormatException('文件过大');
      final template = AmsTagTemplate.importBytes(
        await file.readAsBytes(),
        fileName: file.name,
      );
      if (!mounted || !_currentAccount) return;
      await widget.repository.save(template, ownerAccount: widget.ownerAccount);
      if (mounted) Navigator.of(context).pop(AmsTemplateChoice.saved(template));
    } on FormatException {
      if (mounted) {
        setState(
          () => _error = '模板无效：需要含 UID、全部 64 块及完整扇区密钥的 1KB 文件。ZIP 请先解压。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '导入或加密保存失败，模板未选用，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AmsTagTemplate template) async {
    if (!_currentAccount) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本机模板？'),
        content: const Text(
          '只删除本机的这份兼容模板，不删除耗材库存，也不修改已写入的标签。未保留源标签或导出文件时无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除模板'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_currentAccount) return;
    setState(() => _busy = true);
    try {
      await widget.repository.delete(
        template.id,
        ownerAccount: widget.ownerAccount,
      );
      if (mounted && _currentAccount) widget.onDeleted?.call(template.id);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '删除失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.78,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('兼容标签模板', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('选择可被 AMS 识别的完整源标签。模板按账号加密保存在本机，不上传密钥或标签原始内容。'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('导入文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(
                              context,
                              const AmsTemplateChoice.read(),
                            ),
                      icon: const Icon(Icons.nfc_rounded),
                      label: const Text('读取源标签'),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('重试'),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (_busy || _templates.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text(
                          '还没有兼容模板\n读取你持有的源标签，或导入完整文件',
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index.isOdd) return const Divider(height: 1);
                final template = _templates[index ~/ 2];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: FilamentSpoolIcon(
                    color: ColorUtils.fromHex(template.colorHex),
                    size: 40,
                  ),
                  title: Text(
                    template.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${template.material} · ${template.colorHex}\nUID ${template.uid}',
                  ),
                  isThreeLine: true,
                  onTap: () =>
                      Navigator.pop(context, AmsTemplateChoice.saved(template)),
                  trailing: IconButton(
                    tooltip: '删除模板',
                    onPressed: () => _delete(template),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                );
              }, childCount: _templates.length * 2 - 1),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '导入只检查数据结构，不代表已验证来源签名或 AMS 兼容性。卸载应用会丢失本机模板。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// This confirmation is intentionally required for every physical restore.
/// The declared carrier type is not inferred from an ordinary NFC scan.
Future<String?> confirmAmsTemplateRestore(
  BuildContext context,
  AmsTagTemplate template,
) {
  String target = 'cuid';
  bool accepted = false;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('确认覆盖目标标签'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '模板：${template.name}\n源标签：${template.material} · ${template.colorHex}\n目标 UID：${template.uid}',
            ),
            const SizedBox(height: 12),
            const Text('只贴目标空白卡，不要贴源标签。会覆盖全部数据、密钥和 UID；中途移开可能造成部分写入。'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                MobileGlassChoiceChip(
                  label: const Text('CUID / Gen2'),
                  selected: target == 'cuid',
                  onSelected: (_) => setState(() {
                    target = 'cuid';
                    accepted = false;
                  }),
                ),
                MobileGlassChoiceChip(
                  label: const Text('FUID'),
                  selected: target == 'fuid',
                  onSelected: (_) => setState(() {
                    target = 'fuid';
                    accepted = false;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              target == 'fuid'
                  ? 'FUID 的 UID 通常仅能修改一次，写入后可能无法重置。'
                  : '需要支持标准 Block 0 写入的兼容卡；普通卡和 Gen1 后门卡不适用。',
            ),
            const SizedBox(height: 8),
            const Text(
              '同一模板的多张复制卡共用身份，不可用来同时独立追踪多卷。AMS 仍看到源模板的参数；第三方资料由 Sohun 映射显示，请核对实际材质和打印参数。',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('我已确认目标卡及上述风险'),
              value: accepted,
              onChanged: (value) => setState(() => accepted = value == true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: accepted ? () => Navigator.pop(context, target) : null,
            child: const Text('确认并开始写入'),
          ),
        ],
      ),
    ),
  );
}
