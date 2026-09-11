import 'package:flutter/material.dart';

import '../../core/constants/personal_spool_policy.dart';
import '../../data/database/database.dart';
import '../../data/models/rfid_tag_identity.dart';
import '../../providers/personal_inventory_action_guard.dart';

/// Shared desktop entry point used by the lifecycle view and the stock card.
Future<void> showRfidSpoolReplacementDialog(
  BuildContext context,
  ConsumableDao dao,
  Consumable item,
) async {
  final account = PersonalInventoryActionGuard.fromContext(context);
  try {
    await account.checkAccess(item.id);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
    return;
  }
  final binding = await dao.getRfidSpoolBindingById(item.id);
  if (!context.mounted) return;
  if (!isConsumableRfidTagType(binding?.tagType)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('只有已确认的 CUID/FUID 可以复用换卷；历史记录已保留')),
    );
    return;
  }
  final controller = TextEditingController(text: '1000');
  final formKey = GlobalKey<FormState>();
  var byRemainder = false;
  final route = DialogRoute<double>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, update) => AlertDialog(
        title: const Text('复用标签，换入新卷'),
        content: SizedBox(
          width: 380,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '确认已把标签换到新卷。旧卷余量、打印消耗和卷号会保留，新卷单独计量。若本机正在打印，将保留旧卷已记账消耗，并让当前供料位的任务从新卷继续扣料。',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: byRemainder
                            ? OutlinedButton(
                                onPressed: () =>
                                    update(() => byRemainder = false),
                                child: const Text(
                                  '按卷数入库',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : FilledButton(
                                onPressed: () {},
                                child: const Text(
                                  '按卷数入库',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: byRemainder
                            ? FilledButton(
                                onPressed: () {},
                                child: const Text(
                                  '按余量入库',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : OutlinedButton(
                                onPressed: () =>
                                    update(() => byRemainder = true),
                                child: const Text(
                                  '按余量入库',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!byRemainder) const Text('数量：1 卷 · 1000 g（1 kg）'),
                  if (byRemainder)
                    TextFormField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: '剩余克数（g）'),
                      validator: (text) {
                        final value = double.tryParse(text?.trim() ?? '');
                        return value == null || !canReusePersonalSpool(value)
                            ? '请输入大于 30 且不超过 1000 g 的剩余克数'
                            : null;
                      },
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    '一次换卷操作只绑定 1 卷；同一 CUID/FUID 资料卡要批量补货请回到“读取资料卡”入口。按余量入库登记一卷余料。',
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(
                  dialogContext,
                  byRemainder
                      ? double.parse(controller.text.trim())
                      : personalSpoolCapacityGrams,
                );
              }
            },
            child: const Text('确认换卷'),
          ),
        ],
      ),
    ),
  );
  final grams = await Navigator.of(context, rootNavigator: true).push(route);
  // Dispose after the route has finished its exit animation and unmounted.
  route.completed.then((_) => controller.dispose());
  if (grams == null || !context.mounted) return;
  try {
    final next = await account.run(
      item.id,
      () => dao.replacePersonalRfidSpool(
        consumableId: item.id,
        initialGrams: grams,
        continueCurrentTask: true,
      ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已登记第 ${next.cycle} 卷，旧卷记录已保留')));
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('换卷失败：$error')));
  }
}
