import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_log.dart';
import '../app_state.dart';
import '../gap_log.dart';
import '../main.dart' show kBrand, kCard, kCard2;

/// 空档自述对话框。
///
/// 用途：用户停止计时后立即询问"这段时间在做什么"。
///
/// 依据官方 APK(v810.0.85)逆向确认，这是手机版的既有功能，端点为
/// `/rest/record`、标签经 `/rest/tags/edit` 管理。i18n key
/// `alert_stop_study_just_now_record` 表明对话框在**停止后立即**弹出，
/// 而不是"下次开始时"——这一点修正了本客户端的初版设计。
/// 按钮语义对齐官方的 `study_dialog_rest_record`(记录)与
/// `study_dialog_rest_skip`(跳过)。
///
/// 设计取舍：
///  - **不阻塞计时**：点跳过直接开始，用户不该被弹窗挡住学习。
///  - **预设优先**：短标签一键选，比让用户打字实际率高得多。
///  - **跳过多短**：空档不足 1 分钟时问"在做什么"是噪声，直接忽略。
class GapPromptDialog extends StatefulWidget {
  final GapInterval gap;

  /// 编辑模式：gap 是一条**已闭合**的记录，点保存时更新它，
  /// 而不是去提交 pendingGap。
  ///
  /// 用途：从托盘直接开始计时时无法弹窗，那种空档会以"未填写"落库；
  /// 没有编辑入口的话这些记录就只能删掉，白白丢掉一段可复盘的信息。
  final bool editing;

  const GapPromptDialog({super.key, required this.gap, this.editing = false});

  /// 打开"编辑已有空档"的对话框。
  static Future<void> showForEdit(BuildContext context, GapInterval gap) {
    AppLog.log('gap.edit: 打开编辑 (start=${gap.start}, '
        'duration=${gap.duration.inSeconds}s, answered=${gap.isAnswered})');
    return showDialog<void>(
      context: context,
      builder: (_) => GapPromptDialog(gap: gap, editing: true),
    );
  }

  /// 低于此时长不询问。真正的判定规则在模型层（kMinMeaningfulGap），
  /// 因为"要不要记录"是数据规则，弹窗只是使用方之一 —— 开始计时时
  /// 丢弃过短空档的逻辑也依赖同一个阈值，两处必须一致。
  static const Duration minMeaningfulGap = kMinMeaningfulGap;

  /// 判断这次是否值得问。
  static bool shouldAsk(GapInterval? gap) {
    if (gap == null) {
      AppLog.log('gap.shouldAsk: 无待补录空档 -> false');
      return false;
    }
    if (!gap.isOpen) {
      AppLog.log('gap.shouldAsk: 空档已闭合 -> false');
      return false;
    }
    final ok = isGapLongEnough(gap.duration);
    AppLog.log('gap.shouldAsk: 已过 ${gap.duration.inSeconds}s '
        '(阈值 ${minMeaningfulGap.inSeconds}s) -> $ok');
    return ok;
  }

  /// 便捷入口：需要问就弹，不需要就直接返回。
  static Future<void> maybeShow(BuildContext context, GapInterval? gap) async {
    AppLog.log('gap.maybeShow: 进入 (gap=${gap == null ? "null" : "${gap.duration.inSeconds}s open=${gap.isOpen}"})');
    if (!shouldAsk(gap)) {
      AppLog.log('gap.maybeShow: 条件不满足，不弹窗');
      return;
    }
    if (!context.mounted) {
      AppLog.log('gap.maybeShow: context 已失效，放弃');
      return;
    }
    AppLog.log('gap.maybeShow: 弹出对话框');
    await showDialog<void>(
      context: context,
      builder: (_) => GapPromptDialog(gap: gap!),
    );
    AppLog.log('gap.maybeShow: 对话框已关闭');
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
    final presets = context.read<AppState>().gapPresets;

    return AlertDialog(
      backgroundColor: kCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            widget.editing ? Icons.edit_outlined : Icons.pause_circle_outline,
            color: kBrand,
            size: 22,
          ),
          const SizedBox(width: 10),
          Text(
            widget.editing ? '编辑这段时间' : '这段时间在做什么？',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.editing
                  ? '$minutes 分钟未计入学习。补上自述内容可以帮助复盘。'
                  : '距离上次停止计时已过去 $minutes 分钟，这段时间没有计入学习。',
              style: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 预设标签
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in presets)
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
        // 跳过：不记录，直接开始学习（对齐 study_dialog_rest_skip）
        // 编辑模式下语义变为"取消"，不应该删掉已有记录。
        TextButton(
          onPressed: () async {
            final app = context.read<AppState>();
            if (widget.editing) {
              Navigator.of(context).pop();
              return;
            }
            await app.discardPendingGap();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(widget.editing ? '取消' : '跳过',
              style: const TextStyle(color: Color(0xFF757575), fontSize: 13)),
        ),
        // 记录/保存：闭合本地 + 同步 /rest/record
        TextButton(
          onPressed: () async {
            final app = context.read<AppState>();
            final activity = _text.text.trim();
            if (widget.editing) {
              await app.updateGapLabel(
                widget.gap,
                tag: _tag,
                activity: activity.isEmpty ? null : activity,
              );
              if (context.mounted) Navigator.of(context).pop();
              return;
            }
            await app.describePendingGap(
              tag: _tag,
              activity: activity.isEmpty ? null : activity,
            );
            await app.commitPendingGap();
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(widget.editing ? '保存' : '记录',
              style: const TextStyle(
                  color: kBrand,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
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
              color: selected ? kBrand : Color(0xFFBDBDBD),
            ),
          ),
        ),
      ),
    );
  }
}
