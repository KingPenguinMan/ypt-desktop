import 'package:flutter/material.dart';

import 'models.dart';

/// 一天的最小统计量。来源可能是 /logs/calendar/home 或 /logs/range/days。
class CalendarPoint {
  final String date; // YYYY-MM-DD
  final int studyMs;

  const CalendarPoint({required this.date, required this.studyMs});

  Duration get duration => Duration(milliseconds: studyMs);
}

/// 一段区间的总览数据。
class DayHistory {
  final String date; // YYYY-MM-DD
  final int totalMs;
  final Map<String, int> byTitle;

  const DayHistory({
    required this.date,
    required this.totalMs,
    this.byTitle = const {},
  });

  bool get hasData => totalMs > 0;

  Duration get duration => Duration(milliseconds: totalMs);
}

/// 热力图色阶。刻意做5 档而非连续渐变——档位比渐变更易读，且和手机版
/// "颜色随时间加深"的观感一致。
///
/// 阈值按小时划分，覆盖典型学习强度：
/// <1h 浅 / 1-2h / 2-4h / 4-6h / >6h 深
class HeatLevel {
  static const List<Color> colors = [
    Color(0xFF1A1A1E), // 0h+ 无数据
    Color(0xFF3D2B1F), // < 1h
    Color(0xFF7A4526), // 1-2h
    Color(0xFFB4682F), // 2-4h
    Color(0xFFE08247), // 4-6h
    Color(0xFFFFA45C), // > 6h
  ];

  /// 返回 0..5 的档位索引。0 表示无数据。
  static int of(Duration d) {
    final h = d.inMinutes / 60.0;
    if (h <= 0) return 0;
    if (h < 1) return 1;
    if (h < 2) return 2;
    if (h < 4) return 3;
    if (h < 6) return 4;
    return 5;
  }

  static Color colorOf(Duration d) => colors[of(d)];

  static String label(Duration d) {
    final m = d.inMinutes;
    if (m <= 0) return '无记录';
    if (m < 60) return '$m 分钟';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? '$h 小时' : '$h 小时 $rem 分';
  }
}

/// 扇形图的一段。用于科目占比。
class PieSlice {
  final String label;
  final int value;
  final Color color;

  const PieSlice({
    required this.label,
    required this.value,
    required this.color,
  });
}

/// 学科占比数据。空数据时也能安全渲染。
class SubjectBreakdown {
  final List<PieSlice> slices;
  final int totalMs;

  const SubjectBreakdown({this.slices = const [], this.totalMs = 0});

  static const SubjectBreakdown empty = SubjectBreakdown();

  bool get isEmpty => slices.isEmpty || totalMs <= 0;

  /// 取占比最高的前 n 个科目，其余合并为"其他"。
  ///
  /// 扇形图超过 5 段就读不出信息了，所以必须折叠尾部。
  static SubjectBreakdown from(Map<String, int> byTitle, List<Subject> subjects,
      {int maxSlices = 5, Color Function(String title)? colorOf}) {
    if (byTitle.isEmpty) return empty;

    final resolved = <MapEntry<String, int>>[];
    for (final e in byTitle.entries) {
      if (e.value > 0) resolved.add(e);
    }
    if (resolved.isEmpty) return empty;
    resolved.sort((a, b) => b.value.compareTo(a.value));

    final colorFor = colorOf ?? _colorFromTitle;

    if (resolved.length <= maxSlices) {
      return SubjectBreakdown(
        slices: [
          for (final e in resolved)
            PieSlice(label: e.key, value: e.value, color: colorFor(e.key)),
        ],
        totalMs: resolved.fold(0, (a, b) => a + b.value),
      );
    }

    final head = resolved.take(maxSlices - 1).toList();
    final tailMs =
        resolved.skip(maxSlices - 1).fold(0, (a, b) => a + b.value);
    return SubjectBreakdown(
      slices: [
        for (final e in head)
          PieSlice(label: e.key, value: e.value, color: colorFor(e.key)),
        PieSlice(
          label: '其他 ${resolved.length - maxSlices + 1} 项',
          value: tailMs,
          color: const Color(0xFF5F5E5A),
        ),
      ],
      totalMs: resolved.fold(0, (a, b) => a + b.value),
    );
  }

  /// 科目名→颜色。优先用科目真实颜色，保证和科目卡片一致。
  static Color _colorFromTitle(String title) {
    // 固定色板，按标题哈希取值。同一科目每次渲染颜色一致。
    const palette = [
      Color(0xFFE8552D),
      Color(0xFF3B82F6),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFF8B5CF6),
      Color(0xFFEC4899),
      Color(0xFF06B6D4),
      Color(0xFF84CC16),
    ];
    var h = 0;
    for (final c in title.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }
}

/// 把科目表与时间快照合成扇形图数据。
SubjectBreakdown buildBreakdown(
    Map<String, int> byTitle, List<Subject> subjects) {
  return SubjectBreakdown.from(
    byTitle,
    subjects,
    colorOf: (title) {
      // 先找同名科目拿真实颜色，找不到再回退哈希色。
      for (final s in subjects) {
        if (s.title == title && s.colorValue != 0xFF888888) {
          return s.color;
        }
      }
      return SubjectBreakdown._colorFromTitle(title);
    },
  );
}
