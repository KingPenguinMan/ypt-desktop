import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

///重启后可恢复的计时会话快照。
///
///为什么必须持久化：`/study/start` 一旦发出，服务端就开始累计时长。若把
/// startedAt 只放在内存里（这是重构前的做法），那么进程被杀掉、崩溃或用户
/// 直接关窗口之后，本地就再也发不出 `/study/stop`——因为 stop 需要当初的
/// startedAt。结果是服务端一直计时，用户以为已经停了。桌面端随手关窗口的
/// 习惯让这个场景比手机端高发得多。
class TimerSnapshot {
  /// 本次会话的开始时间，epoch 毫秒。与 `/study/stop` 的 startedAt 一致。
  final int startedAtMs;

  /// 科目 id。用于和 `reloadInfo` 返回的 subjects 对齐。
  final int subjectId;

  /// 科目名。服务端 subjects 里可能找不到对应 id（科目被删/改名）时的兜底。
  final String subjectTitle;

  /// 科目颜色（ARGB int），恢复时重建 Subject 用。
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

  /// 解析失败返回 null——宁可当作"没有快照"，也不要用半截数据去 stop 一个
  /// 错误的时间戳，那样会污染服务端记录。
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

/// 计时会话的本地持久化。
///
/// 单独成一个类而不是塞进 [AppState]，是为了让"存什么"这件事有唯一出口，
/// 方便以后加"空档自述"记录时复用同一套读写。
class TimerPersistence {
  static const String _key = 'active_timer_v1';

  Future<void> save(TimerSnapshot snapshot) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(snapshot.toJson()));
  }

  Future<TimerSnapshot?> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return TimerSnapshot.fromJson(jsonDecode(raw));
    } catch (_) {
      // 存了但坏了：清掉，避免每次启动都走到这个坏分支。
      await sp.remove(_key);
      return null;
    }
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key);
  }
}
