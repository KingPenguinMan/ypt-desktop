import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gap_log.dart';
import '../main.dart' show kBrand, kCard, kCard2;

/// 空档自述对话框。
///
///用途：用户停止计时后、下次开始前，询问"这段不在计时的时间在做什么"。
/// 这是手机版的既有行为，PC 端同样需要——否则统计里会出现一段无法解释的
/// 时间空白。
///
/// 设计取舍：
///  - **不阻塞**：返回 null 表示"暂不填写"，直接开始计时。用户不该被弹窗
///    挡住学习。可以之后再补。
///  - **预设优先**：10 个短标签一键选，比让用户打字实际率高得多。
///  - **跳过多短**：空档不足 1 分钟时问"在做什么"是噪声，直接忽略。
class GapPromptDialog extends StatefulWidget {
  final GapInterval gap;
  const GapPromptDialog({super.key, required this.gap});

  /// 低于此时长不询问。
  static const Duration minMeaningfulGap = Duration(minutes: 1);

  /// 判断这次是否值得问。
  static bool shouldAsk(GapInterval? gap) {
    if (gap == null) return false;
    if (!gap.isOpen) return false;
    return gap.duration >= minMeaningfulGap;
  }

  /// 便捷入口：需要问就弹，不需要就直接返回。
  static Future<void> maybeShow(BuildContext context, GapInterval? gap) async {
    if (!shouldAsk(gap)) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => GapPromptDialog(gap: gap!),
    );
  }

  @override
  State<GapPromptDialog> createState() => _GapPromptDialogState();
}

class _GapPromptDialogState extends State<GapPromptDialog> {
  final _text = TextEditingController();
  String? _tag;

  @override
  void initState() {
    super.initState();
    // 崩溃重启后恢复的记录可能已经填过，回填让用户能修改。
    _tag = widget.gap.tag;
    _text.text = widget.gap.activity ?? '';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gap = widget.gap;
    final minutes = gap.duration.inMinutes;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      backgroundColor: kCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.pause_circle_outline, color: kBrand, size: 22),
          const SizedBox(width: 10),
          const Text('这段时间在做什么？',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '你停止了计时 $minutes 分钟，期间不在学习状态。',
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 预设标签
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in context.read<AppState>().gapPresets)
                  _TagChip(
                    label: tag,
                    selected: _tag == tag,
                    onTap: () => setState(
                        () => _tag = _tag == tag ? null : tag),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '补充说明（可选）',
                hintStyle: TextStyle(color: scheme.outline, fontSize: 13),
                filled: true,
                fillColor: kCard2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('暂不填写',
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        ),
        TextButton(
          onPressed: () async {
            final app = context.read<AppState>();
            final activity = _text.text.trim();
            // 什么都没选也没写 → 视为放弃记录。
            if (_tag == null && activity.isEmpty) {
              await app.discardPendingGap();
            } else {
              await app.describePendingGap(
                tag: _tag,
                activity: activity.isEmpty ? null : activity,
              );
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('保存',
              style:
                  TextStyle(color: kBrand, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? kBrand.withValues(alpha: 0.2) : kCard2,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? kBrand : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? kBrand : Colors.grey[400],
            ),
          ),
        ),
      ),
    );
  }
}
