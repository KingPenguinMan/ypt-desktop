import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gap_log.dart';
import '../history_models.dart';
import '../main.dart' show kBrand, kCard;
import 'calendar_heatmap.dart';
import 'gap_prompt_dialog.dart';
import 'subject_pie_chart.dart';

/// 日历/热力图 + 扇形图。独立成页而非塞进 StatsView。
///
///为什么单独一页：这三块（热力图、扇形图、空档复盘）都属于"回顾"性质，
/// 而 StatsView 是"今天的状态"。挤在一起会让今天的数据被历史淹没。
class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      if (_loaded) return;
      _loaded = true;
      // 默认看最近 90 天。要更长可以调这个数，但注意是 N 次请求。
      app.loadHistory(days: 90);
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final today = DateTime.now();
    final todayKey = formatDate(today);
    final selected = st.selectedDate;

    return RefreshIndicator(
      onRefresh: () => st.loadHistory(days: 90),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Text('Activity history',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (st.historyLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Last 90 days · tap a day for details',
            style: TextStyle(color: Color(0xFF757575), fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (st.historyErrorText != null) ...[
            Text(st.historyErrorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            const SizedBox(height: 8),
          ],

          // ── 待补录的空档提示 ──
          // 重启后恢复的未闭合空档会出现在这里，不会丢失。
          if (st.hasPendingGap && st.pendingGap!.isOpen) ...[
            const SizedBox(height: 14),
            _PendingGapBanner(gap: st.pendingGap!),
          ],
          if (st.gapSyncErrorText != null) ...[
            const SizedBox(height: 8),
            Text(st.gapSyncErrorText!,
                style:
                    const TextStyle(color: Colors.redAccent, fontSize: 11)),
          ],

          // ── 日历热力图 ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CalendarHeatmap(
                  data: st.history,
                  today: today,
                  selectedDate: selected,
                  onSelect: (d) => st.selectDate(d),
                ),
                if (selected != null) ...[
                  const SizedBox(height: 6),
                  SelectedDayCard(
                    date: selected,
                    total: st.history[selected] ?? Duration.zero,
                    byTitle: st.historySubjects[selected] ?? const {},
                    onClose: () => st.selectDate(todayKey),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── 扇形图：今天各科目占比 ──
          const Text('Today by subject',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SubjectPieChart(
              data: buildBreakdown(
                st.subjectTimes,
                st.user?.subjects ?? const [],
              ),
              size: 170,
            ),
          ),
          const SizedBox(height: 20),

          // ── 空档复盘 ──
          const _GapSection(),
        ],
      ),
    );
  }
}

/// 待补录的空档提示条。
///
/// 场景：停止计时后弹窗被关掉（崩溃、切标签页、点了 History），空档仍未
/// 闭合。放在这里给用户一个补录入口，避免"忘记自己在休息"变成永久盲区。
class _PendingGapBanner extends StatelessWidget {
  final GapInterval gap;
  const _PendingGapBanner({required this.gap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBrand.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.pending_actions, size: 16, color: kBrand),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 ${gap.duration.inMinutes} 分钟未记录',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => GapPromptDialog.maybeShow(context, gap),
            child: const Text('补录',
                style: TextStyle(color: kBrand, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 空档自述记录列表。
///
/// 这是"记录不在计时的时间在做什么"的复盘入口。数据是纯本地的（服务端
/// 没有对应端点，详见 ypt_api_probe_report.md）。
class _GapSection extends StatefulWidget {
  const _GapSection();

  @override
  State<_GapSection> createState() => _GapSectionState();
}

class _GapSectionState extends State<_GapSection> {
  List<GapInterval> _entries = [];
  Duration _total = Duration.zero;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final entries = await app.gapEntries();
    final total = await app.gapDuration();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _total = total;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Untimed time',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_total > Duration.zero)
              Text('today ${_fmtDur(_total)}',
                  style: const TextStyle(fontSize: 12, color: kBrand)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Gaps between study sessions, and what you said you were doing.',
          style: TextStyle(color: Color(0xFF757575), fontSize: 11),
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_entries.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const Icon(Icons.self_improvement,
                    size: 22, color: Color(0xFF757575)),
                const SizedBox(height: 8),
                const Text('No gaps recorded today',
                    style:
                        TextStyle(fontSize: 13, color: Color(0xFF757575))),
                const SizedBox(height: 4),
                const Text(
                  'Stop the timer, wait a bit, then start again — you\'ll be asked what you did in between.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
                ),
              ],
            ),
          )
        else ...[
          for (final e in _entries.take(12))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _GapRow(entry: e, onChanged: _load),
            ),
          if (_entries.length > 12)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('…另有 ${_entries.length - 12} 条',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF757575))),
            ),
        ],
      ],
    );
  }
}

class _GapRow extends StatelessWidget {
  final GapInterval entry;
  /// 删除成功后通知父级刷新列表。
  ///
  /// 不能在这里直接调父级的 _load——_GapRow 是独立类，拿不到
  /// _GapSectionState 的方法。
  final VoidCallback onChanged;

  const _GapRow({required this.entry, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tag = entry.tag;
    final activity = entry.activity ?? '';
    final dur = entry.duration;
    final start = entry.start;

    // 整行可点，点开补填自述内容。
    //
    // 没有这个入口的话，"未填写"的记录就是死数据：用户只能删掉，
    // 等于白丢一段可复盘的信息。从托盘直接开始计时产生的记录尤其需要它
    // —— 那条路径没有合适的时机弹窗。
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => GapPromptDialog.showForEdit(context, entry),
        borderRadius: BorderRadius.circular(10),
        child: _buildCard(context, tag, activity, dur, start),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    String? tag,
    String activity,
    Duration dur,
    DateTime start,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            // Color(0xFF757575) 是非空常量，不需要 ! 断言。
            color: tag == null ? const Color(0xFF757575) : kBrand,
            width: 2.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (tag != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: kBrand.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(tag,
                            style: const TextStyle(
                                fontSize: 11,
                                color: kBrand,
                                fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        activity.isEmpty ? '点击补填这段时间在做什么' : activity,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: activity.isEmpty
                              ? Color(0xFF757575)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_hm(start)} · ${_fmtDur(dur)}',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
                ),
              ],
            ),
          ),
          IconButton(
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.only(left: 8),
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
            tooltip: 'Delete',
            onPressed: () => _confirmDelete(context, entry),          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, GapInterval gap) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('删除这条记录？', style: TextStyle(fontSize: 16)),
        content: Text('${_hm(gap.start)} 起的 ${_fmtDur(gap.duration)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await app.deleteGap(gap);
      onChanged();
    }
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _fmtDur(Duration d) {
  final m = d.inMinutes;
  if (m <= 0) return '0m';
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  final rem = m % 60;
  return rem == 0 ? '${h}h' : '${h}h ${rem}m';
}
