// 日历解析器行为测试。
//
// 验证 lib/ypt_api.dart 里 YptApi.parseCalendarPoints / _parseLooseDate 的
// 行为。这里复制一份实现（不是 import），因为原文件依赖 http 包，无法在
// 无 Flutter 环境的纯 Dart 下加载。
//
// 目的：这两个方法是"响应结构未确认"情况下的兜底解析器，必须对各种
// 畸形输入稳定返回，且绝不抛异常 —— 否则会连带打挂整个热力图加载。
import 'dart:io';

class CalendarPoint {
  final String date;
  final int studyMs;
  const CalendarPoint({required this.date, required this.studyMs});
}

class ApiParse {
  // ↓↓↓ 自动同步自 lib/ypt_api.dart（改实现请重新同步）↓↓↓
  static List<CalendarPoint> parseCalendarPoints(Map<String, dynamic> json) {
    final out = <CalendarPoint>[];

    // 후보 컨테이너: 응답 전체, 그리고 배열 필드들.
    final containers = <Map<String, dynamic>>[json];
    for (final v in json.values) {
      if (v is List) {
        for (final item in v) {
          if (item is Map) containers.add(item.cast<String, dynamic>());
        }
      }
    }

    final seen = <String>{};
    for (final c in containers) {
      for (final entry in c.entries) {
        final key = entry.key.toLowerCase();
        // 날짜를 찾는 형태는 두 가지다:
        //   (a) 키가 date/dt/d/day 이고 값이 날짜 문자열
        //   (b) 키 그 자체가 날짜 문자열 (인라인 맵 {'2026-10-01': 7200000})
        // (b) 를漏하면 응답 형태 하나를 통째로 못 읽는다.
        final namedDateKey =
            key == 'date' || key == 'dt' || key == 'd' || key == 'day';
        final inlineDateKey =
            !namedDateKey && _parseLooseDate(entry.key) != null;
        if (!namedDateKey && !inlineDateKey) continue;

        // (a) 는 값에서 날짜를 뽑고, (b) 는 키가 곧 날짜다.
        final date = namedDateKey
            ? _parseLooseDate(entry.value)
            : _parseLooseDate(entry.key);
        if (date == null) continue;

        var ms = 0;
        if (inlineDateKey) {
          // 인라인 형태에서는 키에 대응하는 값이 곧 밀리초다.
          if (entry.value is num) ms = (entry.value as num).toInt();
        } else {
          // 같은 컨테이너에서 시간 값을 찾는다.
          for (final probe
              in ['sm', 'ms', 'studyMs', 'studyms', 'time', 'total']) {
            final v2 = c[probe];
            if (v2 is num) {
              ms = v2.toInt();
              break;
            }
          }
          // 값 자체가 ms 라면(길이 1인 폴백)도 처리.
          if (ms == 0 && entry.value is num) {
            ms = (entry.value as num).toInt();
          }
        }
        if (ms < 0) continue;
        if (seen.add(date)) out.add(CalendarPoint(date: date, studyMs: ms));
      }
    }
    return out;
  }

  /// 'YYYY-MM-DD' / 'YYYYMMDD' / ISO8601 등 관용 파싱.
  ///
  /// epoch 를 날짜로 바꿀 때는 반드시 KST(UTC+9) 기준이어야 한다. YPT 서버의
  /// `dt` 는 한국 시간이고, 로컬 타임존으로 변환하면 자정 근처에서 하루가
  /// 어긋난다. (실측: 1700000000000 은 UTC 로는 11-14, KST 로는 11-15.)
  static String? _parseLooseDate(Object? value) {
    if (value is int) {
      final ms = value > 9999999999 ? value : value * 1000;
      final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
          .add(const Duration(hours: 9));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    if (value is! String) return null;
    final s = value.trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})').firstMatch(s);
    if (m == null) return null;
    return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
  }
  // ↑↑↑ 复制结束 ↑↑↑
}

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  PASS  $name');
  } else {
    _fail++;
    print('  FAIL  $name  -> $detail');
  }
}

void main() {
  print('\n=== _parseLooseDate 输入处理 ===');
  final p = ApiParse._parseLooseDate;
  check('YYYY-MM-DD', p('2026-10-02') == '2026-10-02', p('2026-10-02'));
  check('YYYYMMDD 无分隔', p('20261002') == '2026-10-02', p('20261002'));
  check('ISO8601 带时间', p('2026-10-02T11:22:33Z') == '2026-10-02');
  check('空格分隔日期时间', p('2026-10-02 11:22:33') == '2026-10-02');
  check('epoch 秒可解析', p(1700000000) != null);
  check('epoch 毫秒可解析', p(1700000000000) != null);
  // YPT 服务端是 KST(UTC+9)，epoch 转日期必须按 KST，不能按本地时区。
  // 1700000000000 = 2023-11-14 22:13:20 UTC → KST 已跨日，为 11-15。
  check('epoch 毫秒按 KST 换算', p(1700000000000) == '2023-11-15',
      p(1700000000000));
  check('epoch 秒按 KST 换算', p(1700000000) == '2023-11-15',
      p(1700000000));
  check('空串 -> null', p('') == null);
  check('非日期文本 -> null', p('hello') == null);
  check('null -> null', p(null) == null);
  check('长度不足 -> null', p('2026') == null);
  check('前后空白应被裁掉', p('  2026-10-02 ') == '2026-10-02');

  print('\n=== 形状A · 数组里带 date+sm ===');
  var r = ApiParse.parseCalendarPoints({
    's': true,
    'ms': [
      {'date': '2026-10-01', 'sm': 3600000},
      {'date': '2026-10-02', 'sm': 0},
    ],
  });
  check('解析出 2 条', r.length == 2, r.length.toString());
  check('第 1 条日期正确', r.isNotEmpty && r[0].date == '2026-10-01');
  check('第 1 条时长 = 1h', r.isNotEmpty && r[0].studyMs == 3600000);
  check('0ms 也保留（当天没学习也是事实）',
      r.length == 2 && r[1].studyMs == 0);

  print('\n=== 形状B · 顶层内联 map ===');
  r = ApiParse.parseCalendarPoints({
    '2026-10-01': 7200000,
    '2026-10-02': 600000,
  });
  check('内联形态可解析', r.length == 2, r.toString());
  check('内联值作时长', r.isNotEmpty && r[0].studyMs == 7200000);

  print('\n=== 形状C · dt 键 + studyMs 字段 ===');
  r = ApiParse.parseCalendarPoints({
    'ms': [
      {'dt': '20260930', 'studyMs': 1234}
    ],
  });
  check('dt 键可解析', r.length == 1 && r[0].date == '2026-09-30', r.toString());
  check('studyMs 字段可识别', r.isNotEmpty && r[0].studyMs == 1234);

  print('\n=== 形状D · 畸形输入不得抛异常 ===');
  // 这几条是核心诉求：解析器是兜底逻辑，崩了会连带打挂热力图整条链路。
  try {
    check('空 map', ApiParse.parseCalendarPoints({}).isEmpty);
    check('date 为 null', ApiParse.parseCalendarPoints({'date': null}).isEmpty);
    check(
        '负数时长被剔除',
        ApiParse.parseCalendarPoints({
          'ms': [
            {'date': '2026-10-01', 'sm': -5}
          ]
        }).isEmpty);
    check(
        '重复日期去重（取首个）',
        ApiParse.parseCalendarPoints({
          'ms': [
            {'date': '2026-10-01', 'sm': 1},
            {'date': '2026-10-01', 'sm': 999},
          ]
        }).length == 1);
    check(
        '无关字段不误判',
        ApiParse.parseCalendarPoints({
          's': true,
          'jwt': 'xxx',
          'ct': 'HS11',
        }).isEmpty);
  } catch (e) {
    _fail++;
    print('  FAIL  畸形输入抛异常了 -> $e');
  }

  print('\n=== 结果 ===');
  print('  passed: $_pass  failed: $_fail');
  if (_fail > 0) {
    print('\n有失败项。\n');
    exit(1);
  }
  print('\n全部通过。\n');
}
