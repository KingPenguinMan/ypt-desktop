import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models.dart';
import '../main.dart' show kBrand;
import 'timer_view.dart' show fmtMs;

class StatsView extends StatefulWidget {
  const StatsView({super.key});
  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final user = st.user!;
    final dl = user.dayLog;
    int t(Subject s) => st.subjectStudyMs(s);
    final subjects = [...user.subjects]..sort((a, b) => t(b).compareTo(t(a)));
    final maxMs =
        subjects.isEmpty ? 1 : subjects.map(t).fold(1, (a, b) => a > b ? a : b);

    return RefreshIndicator(
      onRefresh: () => context.read<AppState>().loadStats(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Today · ${AppState.todayStr()}',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (st.statsErrorText != null) ...[
            const SizedBox(height: 8),
            Text(st.statsErrorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          // 요약 카드
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _stat('Study', fmtMs(dl?.studyMs ?? 0), const Color(0xFFE8552D)),
              _stat(
                  'Max session', fmtMs(dl?.maxStudyMs ?? 0), Colors.blueAccent),
              _stat('Added', fmtMs(dl?.addedMs ?? 0), Colors.greenAccent),
              if ((dl?.restMs ?? 0) > 0)
                _stat('Rest', fmtMs(dl!.restMs), Colors.grey),
            ],
          ),
          const SizedBox(height: 24),
          // 과목별 막대
          const Text('By Subject',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...subjects.map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                        width: 120,
                        child: Text(s.title, overflow: TextOverflow.ellipsis)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maxMs == 0 ? 0 : t(s) / maxMs,
                          minHeight: 14,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation(s.color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                        width: 76,
                        child: Text(fmtMs(t(s)),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: Colors.grey,
                                fontFeatures: [FontFeature.tabularFigures()]))),
                  ],
                ),
              )),
          const SizedBox(height: 24),
          // 내 랭킹
          Text(
              'Category Ranking${user.category.isNotEmpty ? ' · ${user.category}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('Top studiers in your category (not a group)',
              style: TextStyle(color: Color(0xFF757575), fontSize: 11)),
          const SizedBox(height: 10),
          // 주기 전환. API 가 이미 day/week/month 를 지원하는데 UI 에 고정돼
          // 있었던 것을 드러낸 것.
          Row(
            children: [
              for (final p in RankPeriod.values) ...[
                _PeriodChip(
                  label: p.label,
                  selected: st.rankPeriod == p,
                  onTap: st.statsLoading
                      ? null
                      : () => context.read<AppState>().setRankPeriod(p),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (st.statsLoading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator()))
          else ...[
            Card(
              child: ListTile(
                leading:
                    const Icon(Icons.emoji_events, color: Color(0xFFE8552D)),
                title: const Text('My Rank'),
                trailing: Text(st.myRank != null ? '#${st.myRank}' : '—',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            if (st.ranks.isNotEmpty)
              Text('${st.rankPeriod.label} · Top Studiers',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ...st.ranks.asMap().entries.map((e) => ListTile(
                  dense: true,
                  leading: CircleAvatar(
                      radius: 14,
                      child: Text('${e.key + 1}',
                          style: const TextStyle(fontSize: 12))),
                  title: Text(e.value.nickname),
                  trailing: Text(fmtMs(e.value.studyMs),
                      style: const TextStyle(
                          color: Colors.grey,
                          fontFeatures: [FontFeature.tabularFigures()])),
                )),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Color(0xFFBDBDBD), fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

/// 랭킹 주기 선택 칩。
class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _PeriodChip({
    required this.label,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? kBrand.withValues(alpha: 0.18) : Colors.white10,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? kBrand : Color(0xFFBDBDBD),
            ),
          ),
        ),
      ),
    );
  }
}
