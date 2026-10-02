import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 低于此时长的空档，既不值得询问，也不该被记录。
///
/// 空档从"停止那一刻"开始累积，而用户常常几秒后就重新开始（切科目、被打断
/// 又马上回来）。把这种空档也写成记录，History 里就会堆出一串
/// "0m · 未填写" 的垃圾条目 —— 既没有信息量，又让人以为记录坏了。
///
/// 定义在模型层而非对话框里：判定"要不要记录"属于数据规则，
/// 弹窗只是其中一个使用方。
const Duration kMinMeaningfulGap = Duration(minutes: 1);

/// 时长是否达到"值得记录并询问"的标准。
///
/// 抽成纯函数而不是散在两个调用点里，有两个原因：
///   1. "要不要记录"必须在弹窗和开始计时两处保持一致，规则只能有一份
///   2. 纯函数可以被自检覆盖 —— 这个 bug（过短空档被无条件写进记录）
///      正是因为没有可验证的判定入口才漏掉的
bool isGapLongEnough(Duration d) => d >= kMinMeaningfulGap;

/// 一次"不在计时的时间"的区间。
///
/// YPT 手机版在停止计时后、再次开始前会询问"这段时间在做什么"，并把回答
/// 记下来。这里用同样的语义建模。
///
/// 重要说明：经实测探测（见 ypt_api_probe_report.md），YPT 服务端当前**没有**
/// 已知的空档记录端点，35+ 个候选路径全部返回 404；而第三方开源实现显示
/// `dl` 结构里只有 `is`（是否计时中）/ `st`（开始时间）/ `sm`（毫秒）三个
/// 计时相关字段，**没有任何自由文本或分类字段**。
///
/// 因此本实现是**纯本地记录**，不做云端同步。理由：
///   1. "复述行为"本质是自律/复盘工具，服务端没有存储它的动机（服务端只
///      关心学习时长这个核心指标）
///   2. 依赖一个可能不存在的端点会把功能做成不可用
///   3. 若后续 RE 出了真端点，只需补一个上传方法，UI 层无需改动
class GapInterval {
  /// 空档开始（即上一次停止计时的时刻）。
  final DateTime start;

  /// 空档结束（即本次开始计时的时刻）。
  final DateTime? end;

  /// 用户自述内容。为空表示尚未填写。
  final String? activity;

  /// 快捷标签（如"吃饭""上厕所""玩手机"）。用于快速选择。
  final String? tag;

  const GapInterval({
    required this.start,
    this.end,
    this.activity,
    this.tag,
  });

  Duration get duration =>
      (end ?? DateTime.now()).difference(start);

  bool get isOpen => end == null;

  /// 是否已被用户回答过（有文字或选了标签）。
  bool get isAnswered => (activity?.trim().isNotEmpty ?? false) || tag != null;

  GapInterval copyWith({
    DateTime? end,
    String? activity,
    String? tag,
  }) =>
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
    final startMs = DateTime.tryParse(raw['start']?.toString() ?? '');
    if (startMs == null) return null;
    return GapInterval(
      start: startMs,
      end: DateTime.tryParse(raw['end']?.toString() ?? ''),
      activity: raw['activity']?.toString(),
      tag: raw['tag']?.toString(),
    );
  }
}

/// 空档记录的本地存储。
///
/// 设计成 append-only 的当日列表：历史留档便于事后复盘"我这周到底有多少
/// 时间在摸鱼"，这也是这个功能真正的价值。
class GapLog {
  static const String _key = 'gap_log_v1';
  static const String _openKey = 'gap_open_v1';

  /// 常见活动类型。刻意做得短且具体——写"吃饭"比写"做其他事情"更有复盘价值。
  static const List<String> presets = <String>[
    '吃饭',
    '上厕所',
    '喝水',
    '玩手机',
    '看视频',
    '发呆',
    '聊天',
    '做杂事',
    '眼睛休息',
    '其他',
  ];

  /// 当天已结束的区间（按开始时间倒序）。
  Future<List<GapInterval>> todayEntries() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_key) ?? const <String>[];
    final out = <GapInterval>[];
    for (final s in raw) {
      final g = GapInterval.fromJson(jsonDecode(s));
      if (g != null && !g.isOpen) out.add(g);
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  /// 读取当前未闭合的空档（上次停止后还没开始新计时）。
  Future<GapInterval?> openGap() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_openKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return GapInterval.fromJson(jsonDecode(raw));
    } catch (_) {
      await sp.remove(_openKey);
      return null;
    }
  }

  Future<void> setOpen(GapInterval gap) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_openKey, jsonEncode(gap.toJson()));
  }

  Future<void> clearOpen() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_openKey);
  }

  /// 闭合一个空档并落进当日列表。
  Future<void> commit(GapInterval gap) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_key) ?? <String>[];
    list.add(jsonEncode(gap.toJson()));
    await sp.setStringList(_key, list);
    await clearOpen();
  }

  /// 删除一条记录（按 start 匹配）。
  ///
  /// 用 start 而非对象相等做键：同一个 start 唯一确定一条记录，而
  /// GapInterval 没有实现 ==，直接 remove 会失效。
  Future<void> remove(GapInterval gap) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_key) ?? <String>[];
    final kept = <String>[];
    for (final s in raw) {
      final g = GapInterval.fromJson(jsonDecode(s));
      if (g != null && g.start == gap.start) continue; // 命中要删的那条
      kept.add(s);
    }
    await sp.setStringList(_key, kept);
  }

  /// 替换一条记录为 [updated]（按 start 匹配）。
  Future<void> update(GapInterval updated) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_key) ?? <String>[];
    final out = <String>[];
    var replaced = false;
    for (final s in raw) {
      final g = GapInterval.fromJson(jsonDecode(s));
      if (g != null && g.start == updated.start) {
        out.add(jsonEncode(updated.toJson()));
        replaced = true;
      } else {
        out.add(s);
      }
    }
    // 没找到就当作新增，避免用户改标签时记录凭空消失。
    if (!replaced) out.add(jsonEncode(updated.toJson()));
    await sp.setStringList(_key, out);
  }

  /// 统计今天未被计入学习时间的空档总时长。
  Future<Duration> todayGapDuration() async {
    final entries = await todayEntries();
    var total = Duration.zero;
    for (final g in entries) {
      total += g.duration;
    }
    return total;
  }

  /// 导出为 CSV 文本。
  ///
  /// 之所以提供导出而不是只做界面：这类数据真正的用法是拿去做月度复盘，
  /// 而复盘通常在表格里做。
  Future<String> toCsv() async {
    final entries = await todayEntries();
    final buf = StringBuffer()
      ..writeln('开始时间,结束时间,时长(分钟),标签,自述内容');
    for (final g in entries) {
      final mins = g.duration.inMinutes;
      buf.writeln([
        _csvCell(g.start.toIso8601String()),
        _csvCell(g.end?.toIso8601String() ?? ''),
        mins,
        _csvCell(g.tag ?? ''),
        _csvCell(g.activity ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  /// CSV 字段转义：含逗号/引号/换行时用双引号包裹，内部引号翻倍。
  static String _csvCell(String value) {
    if (value.isEmpty) return '';
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
