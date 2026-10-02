import 'package:flutter/material.dart';

import '../history_models.dart';
import '../main.dart' show kBrand, kCard;

/// 日历热力图。
///
/// 交互：点选某一天 → 回调 [onSelect]，由外部展示那天的明细。
///
/// 布局刻意做成 GitHub 贡献图的形状（列=周，行=周内日），因为这是用户
/// 最熟悉的心智模型，不需要学习成本。
class CalendarHeatmap extends StatelessWidget {
  /// date -> 当天总时长。缺失的日期按 0 处理。
  final Map<String, Duration> data;

  /// 当前选中的日期（YYYY-MM-DD）。
  final String? selectedDate;

  /// 今天（用于描边高亮）。
  final DateTime today;

  final ValueChanged<String>? onSelect;

  /// 显示多少周。默认 18 周≈4 个月，够看一个季度的趋势。
  final int weeks;

  /// 单元格边长。
  final double cellSize;

  const CalendarHeatmap({
    super.key,
    required this.data,
    required this.today,
    this.selectedDate,
    this.onSelect,
    this.weeks = 18,
    this.cellSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    // 以「今天所在周」为最后一列，向前推 weeks 周。
    final end = _startOfWeek(today);
    final start = end.subtract(Duration(days: 7 * (weeks - 1)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 月份标签
        SizedBox(
          height: 16,
          child: Row(
            children: [
              for (var w = 0; w < weeks; w++)
                SizedBox(
                  width: cellSize + 3,
                  child: _monthLabel(start.add(Duration(days: 7 * w))),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 星期标签（只标一三五，够定位又不拥挤）
            SizedBox(
              width: 18,
              child: Column(
                children: [
                  for (var d = 0; d < 7; d++)
                    SizedBox(
                      height: cellSize + 3,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          d % 2 == 1 ? _weekdayLabel(d) : '',
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // 热力格子
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var w = 0; w < weeks; w++)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Column(
                          children: [
                            for (var d = 0; d < 7; d++)
                              _buildCell(
                                start.add(Duration(days: 7 * w + d)),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Legend(data: data),
      ],
    );
  }

  Widget _buildCell(DateTime date) {
    final key = formatDate(date);
    final dur = data[key] ?? Duration.zero;
    final isToday = _sameDay(date, today);
    final isSelected = selectedDate == key;
    // 未来的格子淡化，避免用户误以为"没记录=没学习"。
    final isFuture = date.isAfter(today);

    return Tooltip(
      message: isFuture
          ? '$key'
          : '${key}\n${HeatLevel.label(dur)}',
      child: GestureDetector(
        onTap: isFuture ? null : () => onSelect?.call(key),
        child: Container(
          width: cellSize,
          height: cellSize,
          margin: const EdgeInsets.only(bottom: 3),
          decoration: BoxDecoration(
            color: isFuture
                ? Colors.transparent
                : HeatLevel.colorOf(dur),
            borderRadius: BorderRadius.circular(3),
            border: isSelected
                ? Border.all(color: kBrand, width: 1.8)
                : isToday
                    ? Border.all(color: Colors.white38, width: 1)
                    : null,
          ),
        ),
      ),
    );
  }

  static String _monthLabel(DateTime weekStart) {
    final m = weekStart.month;
    final prev = weekStart.subtract(const Duration(days: 7)).month;
    // 只在跨月的那一周显示月份名。
    return m != prev ? '$m月' : '';
  }

  static String _weekdayLabel(int day) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return labels[day];
  }
}

/// 色阶图例。
class _Legend extends StatelessWidget {
  final Map<String, Duration> data;
  const _Legend({required this.data});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('少',
            style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        const SizedBox(width: 6),
        for (final c in HeatLevel.colors)
          Container(
            width: 11,
            height: 11,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        const SizedBox(width: 3),
        const Text('多',
            style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        const Spacer(),
        // 显示有记录的天数，这是热力图最直接的总结论。
        Text(
          '${data.values.where((d) => d > Duration.zero).length} 天有记录',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }
}

/// 某个选中日期的明细卡。
class SelectedDayCard extends StatelessWidget {
  final String date;
  final Duration total;
  final Map<String, int> byTitle;
  final VoidCallback? onClose;

  const SelectedDayCard({
    super.key,
    required this.date,
    required this.total,
    required this.byTitle,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final entries = byTitle.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBrand.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event, size: 15, color: kBrand),
              const SizedBox(width: 8),
              Text(date,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(HeatLevel.label(total),
                  style: const TextStyle(
                    fontSize: 13,
                    color: kBrand,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  )),
              if (onClose != null)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.only(left: 8),
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: onClose,
                ),
            ],
          ),
          if (entries.isEmpty) ...[
            const SizedBox(height: 8),
            const Text('当天没有学习记录',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ] else ...[
            const SizedBox(height: 10),
            for (final e in entries.take(8))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(e.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text(_hm(e.value),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontFeatures: [FontFeature.tabularFigures()],
                        )),
                  ],
                ),
              ),
            if (entries.length > 8)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('…另有 ${entries.length - 8} 个科目',
                    style: const TextStyle(fontSize: 11, color: Colors.grey[600])),
              ),
          ],
        ],
      ),
    );
  }

  static String _hm(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

/// YYYY-MM-DD。不能用 toIso8601String 的其他变体，日历 key 必须统一格式。
String formatDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 该日期所在周的周一。
DateTime _startOfWeek(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  // Dart 的 weekday: Mon=1 ... Sun=7
  return day.subtract(Duration(days: day.weekday - 1));
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
