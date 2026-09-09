import 'dart:async';

import '../../core/theme/glass_button_theme.dart';
import 'package:flutter/material.dart';

import '../../core/utils/friendly_error.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../data/external/printer/bambu_bind_traffic_sniffer.dart';
import '../../widgets/confirm_dialog.dart';

/// 跨设备绑定流量嗅探对话框（研究工具）。
///
/// 目的：在用户正常执行 PIN 码绑定流程时，监听打印机的 MQTT 流量，
/// 抓取打印机固件在用户按下"绑定"按钮时发布的 confirm 消息格式。
/// 拿到 confirm 消息格式后，理论上可以通过主动注入该消息绕过物理按键。
///
/// **使用流程**（对话框内顶部有指引）：
/// 1. 在打印机屏幕进入"设置 > 账号 > PIN 码绑定"，记下 PIN 码
/// 2. 在本对话框输入打印机 IP、access code、序列号
/// 3. 点击"开始嗅探"按钮
/// 4. 在 Bambu Studio 执行 PIN 码绑定
/// 5. **关键时刻**：在打印机屏幕按下"绑定"按钮
/// 6. 观察本对话框中的消息流，黄色/绿色高亮的是 bind 相关消息
/// 7. 点击"导出 JSONL"保存日志用于分析
class BindSnifferDialog extends StatefulWidget {
  /// 预填的打印机 IP（如果已选中打印机则自动填入）
  final String? initialPrinterIp;

  /// 预填的 access code
  final String? initialAccessCode;

  /// 预填的序列号
  final String? initialSerial;

  const BindSnifferDialog({
    super.key,
    this.initialPrinterIp,
    this.initialAccessCode,
    this.initialSerial,
  });

  @override
  State<BindSnifferDialog> createState() => _BindSnifferDialogState();
}

class _BindSnifferDialogState extends State<BindSnifferDialog> {
  late final TextEditingController _ipController;
  late final TextEditingController _accessCodeController;
  late final TextEditingController _serialController;

  BambuBindTrafficSniffer? _sniffer;
  BindSnifferState _state = BindSnifferState.idle;
  String? _errorMessage;

  /// 所有捕获的消息（用于列表显示）
  final List<BindTrafficEvent> _events = [];

  /// 滚动控制器（自动滚动到最新消息）
  final ScrollController _scrollController = ScrollController();

  /// 是否只显示 bind 相关消息（过滤掉心跳和无关注消息）
  bool _onlyBindRelated = false;

  StreamSubscription<BindTrafficEvent>? _eventSub;
  StreamSubscription<BindSnifferState>? _stateSub;
  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(text: widget.initialPrinterIp ?? '');
    _accessCodeController = TextEditingController(
      text: widget.initialAccessCode ?? '',
    );
    _serialController = TextEditingController(text: widget.initialSerial ?? '');
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _errorSub?.cancel();
    _sniffer?.dispose();
    _ipController.dispose();
    _accessCodeController.dispose();
    _serialController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 启动嗅探
  Future<void> _start() async {
    final ip = _ipController.text.trim();
    final accessCode = _accessCodeController.text.trim();
    final serial = _serialController.text.trim();

    if (ip.isEmpty || accessCode.isEmpty || serial.isEmpty) {
      setState(() => _errorMessage = '请填写 IP / access code / 序列号');
      return;
    }

    setState(() {
      _errorMessage = null;
      _events.clear();
    });

    _sniffer = BambuBindTrafficSniffer(
      mode: BindSniffMode.lan,
      host: ip,
      port: 8883,
      username: 'bblp',
      password: accessCode,
      serial: serial,
    );

    _eventSub = _sniffer!.eventStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _events.add(event);
        // 限制内存中最多保留 5000 条，超过自动丢旧的
        if (_events.length > 5000) {
          _events.removeRange(0, _events.length - 5000);
        }
      });
      // 自动滚动到底部
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    });

    _stateSub = _sniffer!.stateStream.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
    });

    _errorSub = _sniffer!.errorStream.listen((msg) {
      if (!mounted) return;
      setState(() => _errorMessage = msg);
    });

    await _sniffer!.start();
  }

  /// 停止嗅探
  Future<void> _stop() async {
    await _sniffer?.stop();
  }

  /// 导出 JSONL 文件
  Future<void> _export() async {
    if (_events.isEmpty) {
      setState(() => _errorMessage = '没有可导出的消息');
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final path = '${dir.path}/bind_capture_$stamp.jsonl';
      await _sniffer?.exportToFile(path);

      if (!mounted) return;
      setState(() => _errorMessage = null);

      // 同时把全部内容放到剪贴板（便于直接粘贴给开发者）
      final buffer = StringBuffer();
      for (final e in _events) {
        buffer.writeln(e.toJsonlLine());
      }
      await Clipboard.setData(ClipboardData(text: buffer.toString()));

      if (!mounted) return;
      showSnack(
        context,
        '已导出到 $path，并复制到剪贴板',
        duration: const Duration(seconds: 5),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '导出失败：${friendlyError(e)}');
    }
  }

  /// 复制单条消息到剪贴板
  Future<void> _copyEvent(BindTrafficEvent event) async {
    await Clipboard.setData(ClipboardData(text: event.toJsonlLine()));
    if (!mounted) return;
    showSnack(
      context,
      '已复制：${event.topic}',
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bindRelatedCount = _events.where((e) => e.isLikelyBindRelated).length;
    final isRunning =
        _state == BindSnifferState.listening ||
        _state == BindSnifferState.connecting;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            // ===== 标题栏 =====
            _buildHeader(isDark),
            const Divider(height: 1),

            // ===== 配置输入区 =====
            _buildConfigSection(isDark, isRunning),

            // ===== 指引提示 =====
            _buildGuide(),

            // ===== 消息列表 =====
            Expanded(
              child: _events.isEmpty
                  ? _buildEmptyState(isDark)
                  : _buildMessageList(isDark),
            ),

            // ===== 底部操作栏 + 统计 =====
            _buildFooter(isDark, isRunning, bindRelatedCount),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        children: [
          Icon(Icons.wifi_tethering, color: AppColors.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bind 流量嗅探器',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '抓取 PIN 码绑定时的 MQTT confirm 消息格式（研究工具）',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () async {
              await _stop();
              if (!mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildConfigSection(bool isDark, bool isRunning) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.02),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _ipController,
                  label: '打印机 IP',
                  hint: '192.168.1.100',
                  icon: Icons.router_outlined,
                  enabled: !isRunning,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _buildTextField(
                  controller: _accessCodeController,
                  label: 'Access Code',
                  hint: 'ABCD1234',
                  icon: Icons.lock_outline,
                  enabled: !isRunning,
                  isDark: isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _serialController,
                  label: '序列号',
                  hint: '00M00A123456789',
                  icon: Icons.qr_code,
                  enabled: !isRunning,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Checkbox(
                      value: _onlyBindRelated,
                      onChanged: (v) =>
                          setState(() => _onlyBindRelated = v ?? false),
                      activeColor: AppColors.primary,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Expanded(
                      child: Text(
                        '只看 bind 相关',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool enabled,
    required bool isDark,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      style: TextStyle(
        fontSize: 12,
        color: isDark ? Colors.white : AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 14),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: 0.1,
            ),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: 0.1,
            ),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildGuide() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: AppColors.warning),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '使用流程：① 打印机进入 PIN 码绑定界面 ② 点击"开始嗅探" ③ '
              '在 Bambu Studio 执行 PIN 绑定 ④ 在打印机屏幕按"绑定"按钮 ⑤ '
              '观察黄色/绿色高亮的 bind 相关消息 ⑥ 导出 JSONL 给开发者分析',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sensors_off_outlined,
            size: 48,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
          const SizedBox(height: 12),
          Text(
            _state == BindSnifferState.connecting
                ? '正在连接打印机 MQTT...'
                : '嗅探器未启动',
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(bool isDark) {
    final filtered = _onlyBindRelated
        ? _events.where((e) => e.isLikelyBindRelated).toList()
        : _events;

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) {
        final event = filtered[i];
        return _MessageTile(
          event: event,
          isDark: isDark,
          onTap: () => _copyEvent(event),
        );
      },
    );
  }

  Widget _buildFooter(bool isDark, bool isRunning, int bindRelatedCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(
              alpha: 0.06,
            ),
          ),
        ),
      ),
      child: Column(
        children: [
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _errorMessage!,
                style: const TextStyle(fontSize: 11, color: AppColors.danger),
              ),
            ),
          Row(
            children: [
              // 统计
              _buildStat('总数', '${_events.length}', isDark),
              const SizedBox(width: 12),
              _buildStat(
                'bind 相关',
                '$bindRelatedCount',
                isDark,
                highlight: bindRelatedCount > 0,
              ),
              const Spacer(),
              // 状态指示
              if (isRunning)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _state == BindSnifferState.connecting ? '连接中' : '监听中',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              // 操作按钮
              if (isRunning)
                ElevatedButton.icon(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop, size: 14),
                  label: const Text('停止', style: TextStyle(fontSize: 12)),
                  style: glassButtonStyle(
                    context,
                    ElevatedButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    variant: AppGlassButtonVariant.primary,
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text('开始嗅探', style: TextStyle(fontSize: 12)),
                  style: glassButtonStyle(
                    context,
                    ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    variant: AppGlassButtonVariant.primary,
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _events.isEmpty ? null : _export,
                icon: const Icon(Icons.download, size: 14),
                label: const Text('导出', style: TextStyle(fontSize: 12)),
                style: glassButtonStyle(
                  context,
                  OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  variant: AppGlassButtonVariant.secondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStat(
    String label,
    String value,
    bool isDark, {
    bool highlight = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: highlight ? AppColors.primary : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 单条消息显示。
class _MessageTile extends StatelessWidget {
  final BindTrafficEvent event;
  final bool isDark;
  final VoidCallback onTap;

  const _MessageTile({
    required this.event,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isBindRelated = event.isLikelyBindRelated;
    final isHeartbeat = event.isHeartbeat;

    // 颜色策略：
    // - bind 相关：黄色/绿色高亮背景
    // - 心跳：灰色，淡显示
    // - 普通消息：正常
    Color? bgColor;
    Color? borderColor;
    if (isBindRelated) {
      bgColor = AppColors.primary.withValues(alpha: 0.08);
      borderColor = AppColors.primary.withValues(alpha: 0.4);
    } else if (isHeartbeat) {
      bgColor = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.02);
    }

    final timeStr =
        '${event.timestamp.hour.toString().padLeft(2, '0')}:'
        '${event.timestamp.minute.toString().padLeft(2, '0')}:'
        '${event.timestamp.second.toString().padLeft(2, '0')}.'
        '${event.timestamp.millisecond.toString().padLeft(3, '0')}';

    final payloadDisplay = event.payloadRaw.length > 300
        ? '${event.payloadRaw.substring(0, 300)}... (${event.payloadRaw.length} bytes)'
        : event.payloadRaw;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(4),
          border: borderColor != null
              ? Border.all(color: borderColor, width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：时间 + topic + 关键字标签
            Row(
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.topic,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: isBindRelated
                          ? AppColors.primary
                          : (isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary),
                      fontWeight: isBindRelated
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isBindRelated) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'BIND',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
                if (isHeartbeat) ...[
                  const SizedBox(width: 4),
                  Text(
                    '♥',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
            if (!isHeartbeat) ...[
              const SizedBox(height: 4),
              // 第二行：payload
              Text(
                payloadDisplay,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: isBindRelated
                      ? (isDark ? Colors.white : AppColors.textPrimary)
                      : (isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary),
                  height: 1.4,
                ),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
              if (event.keywordsHit.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: event.keywordsHit.map((kw) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          kw,
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.warning,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
