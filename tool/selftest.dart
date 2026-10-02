// 核心逻辑自检 —— 纯 Dart,不依赖 Flutter / shared_preferences。
//
// 为什么单独放一个文件:lib/ 下的存储类都import shared_preferences,
// 在没有 Flutter package 的环境里无法加载。把「与存储无关的纯逻辑」
// 复制到这里独立验证,存储层本身靠集成测试覆盖。
//
// 运行: dart run tool/selftest.dart
import 'dart:convert';
import 'dart:io';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  PASS  $name');
  } else {
    _fail++;
    print('  FAIL  $name${detail == null ? '' : '  -> $detail'}');
  }
}

// ── 以下镜像 lib/timer_persistence.dart 与 lib/gap_log.dart 的纯逻辑 ──

class TimerSnapshot {
  final int startedAtMs;
  final int subjectId;
  final String subjectTitle;
  final int subjectColor;

  const TimerSnapshot({
    required this.startedAtMs,
    required this.subjectId,
    required this.subjectTitle,
    required this.subjectColor,
  });

  Map<String, dynamic> toJson() => {
        'startedAt': startedAtMs,
        'subjectId': subjectId,
        'title': subjectTitle,
        'color': subjectColor,
      };

  static TimerSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final startedAt = _intOf(raw['startedAt']);
    if (startedAt == null || startedAt <= 0) return null;
    return TimerSnapshot(
      startedAtMs: startedAt,
      subjectId: _intOf(raw['subjectId']) ?? 0,
      subjectTitle: raw['title']?.toString() ?? '',
      subjectColor: _intOf(raw['color']) ?? 0xFF888888,
    );
  }

  static int? _intOf(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

class GapInterval {
  final DateTime start;
  final DateTime? end;
  final String? activity;
  final String? tag;

  const GapInterval({required this.start, this.end, this.activity, this.tag});

  Duration get duration => (end ?? DateTime.now()).difference(start);

  bool get isOpen => end == null;

  bool get isAnswered => (activity?.trim().isNotEmpty ?? false) || tag != null;

  GapInterval copyWith({DateTime? end, String? activity, String? tag}) =>
      GapInterval(
        start: start,
        end: end ?? this.end,
        activity: activity ?? this.activity,
        tag: tag ?? this.tag,
      );

  Map<String, dynamic> toJson() => {
        'start': start.toIso8601String(),
        'end': end?.toIso8601String(),
        'activity': activity,
        'tag': tag,
      };

  static GapInterval? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = DateTime.tryParse(raw['start']?.toString() ?? '');
    if (s == null) return null;
    return GapInterval(
      start: s,
      end: DateTime.tryParse(raw['end']?.toString() ?? ''),
      activity: raw['activity']?.toString(),
      tag: raw['tag']?.toString(),
    );
  }
}

/// 热力图分档。镜像 lib/history_models.dart 的 HeatLevel.of。
int heatLevel(Duration d) {
  final h = d.inMinutes / 60.0;
  if (h <= 0) return 0;
  if (h < 1) return 1;
  if (h < 2) return 2;
  if (h < 4) return 3;
  if (h < 6) return 4;
  return 5;
}

String heatLabel(Duration d) {
  final m = d.inMinutes;
  if (m <= 0) return '无记录';
  if (m < 60) return '$m 分钟';
  final h = m ~/ 60;
  final rem = m % 60;
  return rem == 0 ? '$h 小时' : '$h 小时 $rem 分';
}

/// CSV 字段转义。镜像 lib/gap_log.dart 的 _csvCell。
String csvCell(String value) {
  if (value.isEmpty) return '';
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

// ── 测试 ──

void main() {
  print('\n=== TimerSnapshot 序列化 ===');

  const snap = TimerSnapshot(
    startedAtMs: 1700000000000,
    subjectId: 42,
    subjectTitle: '线代',
    subjectColor: 0xFFE8552D,
  );
  final rt = TimerSnapshot.fromJson(jsonDecode(jsonEncode(snap.toJson())));
  check('往返后 startedAt 一致', rt?.startedAtMs == 1700000000000);
  check('往返后 subjectId 一致', rt?.subjectId == 42);
  check('往返后标题一致', rt?.subjectTitle == '线代');
  check('往返后颜色一致', rt?.subjectColor == 0xFFE8552D);

  // 坏数据必须判 null——否则会用错误时间戳去 stop,污染服务端记录。
  check('缺 startedAt -> null', TimerSnapshot.fromJson({'x': 1}) == null);
  check('startedAt=0 -> null',
      TimerSnapshot.fromJson({'startedAt': 0}) == null);
  check('startedAt 为负 -> null',
      TimerSnapshot.fromJson({'startedAt': -5}) == null);
  check('非 Map -> null', TimerSnapshot.fromJson('garbage') == null);
  check('null -> null', TimerSnapshot.fromJson(null) == null);
  check(
    '字符串数字可解析',
    TimerSnapshot.fromJson({'startedAt': '1700000000000'})?.startedAtMs ==
        1700000000000,
  );
  check(
    '缺 color 时用默认灰',
    TimerSnapshot.fromJson({'startedAt': 1})?.subjectColor == 0xFF888888,
  );

  print('\n=== GapInterval 区间与闭合 ===');

  final t0 = DateTime(2026, 10, 2, 14);
  final open = GapInterval(start: t0);
  check('新建区间为 open', open.isOpen);
  check('open 时 isAnswered=false', !open.isAnswered);

  final closed = open.copyWith(
    end: t0.add(const Duration(minutes: 25)),
    tag: '吃饭',
  );
  check('闭合后不再 open', !closed.isOpen);
  check('时长计算正确', closed.duration == const Duration(minutes: 25),
      '实际 ${closed.duration}');
  check('有标签即已回答', closed.isAnswered);
  check('有文字即已回答', open.copyWith(activity: '看手机').isAnswered);
  check('copyWith 保留 start', closed.copyWith(tag: 'x').start == t0);
  check(
    'copyWith 不覆盖未提及字段',
    closed.copyWith(end: t0.add(const Duration(hours: 1))).tag == '吃饭',
  );

  print('\n=== GapInterval 序列化 ===');

  final gj = GapInterval.fromJson(jsonDecode(jsonEncode(closed.toJson())));
  check('往返后 start 一致', gj?.start == t0);
  check('往返后 end 一致', gj?.end == closed.end);
  check('往返后 tag 一致', gj?.tag == '吃饭');
  check(
    '坏 start -> null',
    GapInterval.fromJson({'start': 'not-a-date'}) == null,
  );
  check('非 Map -> null', GapInterval.fromJson(42) == null);
  check(
    '缺 end 时视为 open',
    GapInterval.fromJson({'start': t0.toIso8601String()})?.isOpen == true,
  );

  print('\n=== 热力图分档 ===');
  check('0 -> 档 0', heatLevel(Duration.zero) == 0);
  check('30分 -> 档 1', heatLevel(const Duration(minutes: 30)) == 1);
  check('1小时 -> 档 2', heatLevel(const Duration(hours: 1)) == 2);
  check('2小时 -> 档 3', heatLevel(const Duration(hours: 2)) == 3);
  check('4小时 -> 档 4', heatLevel(const Duration(hours: 4)) == 4);
  check('6小时 -> 档 5', heatLevel(const Duration(hours: 6)) == 5);
  check('12小时 -> 仍是档 5', heatLevel(const Duration(hours: 12)) == 5);
  check('边界 59分59秒 -> 档 1',
      heatLevel(const Duration(minutes: 59, seconds: 59)) == 1);

  print('\n=== 时长文案 ===');
  check('0 -> 无记录', heatLabel(Duration.zero) == '无记录');
  check('45分 -> 45 分钟', heatLabel(const Duration(minutes: 45)) == '45 分钟');
  check('2小时 -> 2 小时', heatLabel(const Duration(hours: 2)) == '2 小时');
  check('2.5小时 -> 2 小时 30 分',
      heatLabel(const Duration(hours: 2, minutes: 30)) == '2 小时 30 分');

  print('\n=== CSV 转义 ===');
  check('普通值不加引号', csvCell('吃饭') == '吃饭');
  check('空串 -> 空', csvCell('') == '');
  check('含逗号 -> 加引号', csvCell('吃饭,喝水') == '"吃饭,喝水"');
  check('含引号 -> 翻倍并包裹', csvCell('say "hi"') == '"say ""hi"""');
  check('含换行 -> 加引号', csvCell('a\nb') == '"a\nb"');

  print('\n=== 结果 ===');
  print('  passed: $_pass   failed: $_fail');
  if (_fail > 0) {
    print('\n有失败项。\n');
    exit(1);
  }
  print('\n全部通过。\n');
}
