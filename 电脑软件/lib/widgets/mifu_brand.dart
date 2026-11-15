import 'package:flutter/material.dart';

import 'mifu_wordmark.dart';

/// Product identity only. These labels never describe the connected engine,
/// grant model readiness, or authorize a printer operation.
abstract final class MifuBrand {
  static const name = 'Mifu';
  static const tagline = '自研数值决策';
  static const description = '由 Sohun 自主设计与训练的数值排序模块';
}

class MifuBrandIdentity extends StatelessWidget {
  const MifuBrandIdentity({super.key, this.width = 96});

  final double width;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MifuWordmark(width: width),
      const SizedBox(height: 2),
      Text(
        MifuBrand.tagline,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

/// Concise product provenance, separate from actual health and acceptance.
/// The third-party details are available on demand, not on the workspace header.
class MifuBrandDetails extends StatelessWidget {
  const MifuBrandDetails({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          MifuBrand.description,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          '研发身份与连接状态分开显示；品牌名称不代表自研模块已在本机启用。',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          key: const ValueKey('mifu-component-information'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          visualDensity: VisualDensity.compact,
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('组件信息', style: TextStyle(fontSize: 12)),
          subtitle: Text(
            '自主研发范围与基础组件',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
          children: const [
            _MifuComponentNote(
              title: 'Sohun 自主研发',
              body: '集群调度交互、数据采集与独立复核流程，以及自主设计与训练的数值排序模块。',
            ),
            _MifuComponentNote(
              title: '基础组件与兼容路径',
              body:
                  '客户端使用 Flutter，数值训练与推理使用 PyTorch 等基础组件。旧版兼容推理路径使用 Laya；这不表示本机正在使用该路径，实际状态以服务反馈为准。',
            ),
            _MifuComponentNote(
              title: '能力与验收边界',
              body: '自研数值排序模块不是从零研发的通用大模型，尚未完成全业务与实机验收。名称、连接状态或离线结果都不构成自动派单授权。',
            ),
          ],
        ),
      ],
    );
  }
}

class _MifuComponentNote extends StatelessWidget {
  const _MifuComponentNote({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
