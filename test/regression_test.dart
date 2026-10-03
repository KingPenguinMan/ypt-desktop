import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ypt_desktop/app_state.dart';
import 'package:ypt_desktop/gap_log.dart';
import 'package:ypt_desktop/hourglass_frames.dart';
import 'package:ypt_desktop/models.dart';
import 'package:ypt_desktop/server_session.dart';
import 'package:ypt_desktop/ypt_api.dart';

const start = 1790906400000;
UserData profile({bool running = true, String id = 'account-a'}) => UserData(
  accountId: id,
  nickname: id,
  category: '',
  subjects: [subject],
  session: ServerSession(
    running,
    startedAtMs: running ? start : null,
    subject: running ? '数学' : null,
  ),
);
final subject = Subject(
  id: 7,
  title: '数学',
  studyMs: 0,
  order: 0,
  colorValue: 0xFFE8552D,
  archived: false,
);

class FakeApi extends YptApi {
  UserData data = profile();
  bool failReload = false;
  bool failAfterStop = false;
  bool failStop = false;
  bool failStart = false;
  int stopCount = 0;
  int? stoppedAt;
  @override
  Future<UserData> reloadInfo() async {
    if (failReload) throw TimeoutException('offline');
    return data;
  }

  @override
  Future<SignInResult> signIn(String email, String password) async {
    jwt = 'new-token';
    return SignInOk(
      UserData(
        accountId: email,
        jwt: jwt,
        nickname: email,
        category: '',
        subjects: [subject],
        session: const ServerSession(false),
      ),
    );
  }

  @override
  Future<SubjectTimeSnapshot> dayLogSubjects(String date) async =>
      const SubjectTimeSnapshot(byTitle: {'数学': 3600000});
  @override
  Future<DayLog?> studyStop(int timestamp) async {
    stopCount++;
    stoppedAt = timestamp;
    if (failStop) throw TimeoutException('stop reply lost');
    data = profile(running: false);
    if (failAfterStop) failReload = true;
    return null;
  }

  @override
  Future<ServerSession?> studyStart(String subject, {int? taskId}) async {
    if (failStart) throw TimeoutException('start reply lost');
    data = profile();
    return data.session;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'jwt': 'saved-token'});
  });
  Future<AppState> logged(FakeApi api) async {
    final app = AppState(api: api);
    addTearDown(app.dispose);
    await app.tryAutoLogin();
    return app;
  }

  test('successful stop is not rolled back by a failed refresh', () async {
    final api = FakeApi()..failAfterStop = true;
    final app = await logged(api);
    expect(app.studying, true);
    expect(await app.stopTimerAndReport(), true);
    expect(app.studying, false);
    expect(app.timerUncertain, false);
    expect(api.stoppedAt, start);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getKeys().any((k) => k.startsWith('active_timer_v2')), false);
    expect(app.pendingGap, isNotNull);
  });
  test(
    'network error on auto-login preserves token and legacy recovery data',
    () async {
      SharedPreferences.setMockInitialValues({
        'jwt': 'saved-token',
        'active_timer_v1': 'legacy-snapshot',
        'gap_open_v1': 'legacy-gap',
      });
      await logged(FakeApi()..failReload = true);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('jwt'), 'saved-token');
      expect(sp.getString('active_timer_v1'), 'legacy-snapshot');
      expect(sp.getString('gap_open_v1'), 'legacy-gap');
    },
  );
  test('failed sign out preserves token and timer snapshot', () async {
    final app = await logged(FakeApi()..failStop = true);
    await app.logout();
    expect(app.loggedIn, true);
    expect(app.timerUncertain, true);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('jwt'), 'saved-token');
    expect(sp.getKeys().any((k) => k.startsWith('active_timer_v2')), true);
  });
  test('legacy JWT without account fields can still start', () async {
    final api = FakeApi()
      ..data = UserData(
        nickname: 'legacy',
        category: '',
        subjects: [subject],
        session: const ServerSession(false),
      );
    final app = await logged(api);
    expect(app.loggedIn, true);
    expect(app.errorText, isNull);
  });
  test('server stop on phone clears a stale desktop timer', () async {
    final api = FakeApi();
    final app = await logged(api);
    api.data = profile(running: false);
    await app.reconcileTimer();
    expect(app.studying, false);
    expect(api.stopCount, 0);
  });
  test(
    'start persists server timestamp, never local click timestamp',
    () async {
      final api = FakeApi()..data = profile(running: false);
      final app = await logged(api);
      await app.startTimer(subject);
      final sp = await SharedPreferences.getInstance();
      final key = sp.getKeys().singleWhere(
        (k) => k.startsWith('active_timer_v2'),
      );
      expect(jsonDecode(sp.getString(key)!)['startedAt'], start);
    },
  );
  test('failed start keeps the open gap intact', () async {
    final api = FakeApi();
    final app = await logged(api);
    await app.stopTimer();
    final gap = app.pendingGap;
    api.failStart = true;
    await app.startTimer(subject);
    expect(app.pendingGap?.start, gap?.start);
    expect(app.timerUncertain, true);
  });
  test('unknown server state never silently becomes stopped', () async {
    final api = FakeApi()
      ..data = UserData(
        accountId: 'a',
        nickname: '',
        category: '',
        subjects: [subject],
      );
    final app = await logged(api);
    expect(app.timerUncertain, true);
    expect(await app.stopTimerAndReport(), false);
    expect(api.stopCount, 0);
  });
  test('logout clears account history and selected details', () async {
    final app = await logged(FakeApi()..data = profile(running: false));
    app.history['2026-10-01'] = const Duration(hours: 1);
    app.historySubjects['2026-10-01'] = {'old': 1};
    app.selectedDate = '2026-10-01';
    await app.logout();
    expect(app.history, isEmpty);
    expect(app.historySubjects, isEmpty);
    expect(app.selectedDate, isNull);
    expect(await app.login('account-b', 'test'), true);
    expect(await app.gapEntries(), isEmpty);
  });
  test('history totals include title-only subject records', () async {
    final app = await logged(FakeApi()..data = profile(running: false));
    await app.loadHistory(days: 1);
    expect(app.history[AppState.todayStr()], const Duration(hours: 1));
  });
  test('gap storage isolates users and filters dates', () async {
    final a = GapLog('a');
    final b = GapLog('b');
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1, 12);
    final noon = DateTime(today.year, today.month, today.day, 12);
    await a.commit(
      GapInterval(
        start: yesterday,
        end: yesterday.add(const Duration(minutes: 20)),
      ),
    );
    await a.commit(
      GapInterval(start: noon, end: noon.add(const Duration(minutes: 10))),
    );
    expect(await a.entriesFor(today), hasLength(1));
    expect(await a.todayGapDuration(), const Duration(minutes: 10));
    expect(await b.entriesFor(today), isEmpty);
  });
  test('cross-midnight gap contributes only the overlap with today', () async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final log = GapLog('a');
    await log.commit(
      GapInterval(
        start: midnight.subtract(const Duration(minutes: 10)),
        end: midnight.add(const Duration(minutes: 5)),
      ),
    );
    expect(await log.todayGapDuration(), const Duration(minutes: 5));
  });
  test('same gap cannot be duplicated by repeated save', () async {
    final log = GapLog('a');
    final now = DateTime.now();
    final gap = GapInterval(
      start: now,
      end: now.add(const Duration(minutes: 1)),
    );
    await log.commit(gap);
    await log.commit(gap);
    expect(await log.entriesFor(now), hasLength(1));
  });
  test('mobile break limits are 15 seconds through 3 hours', () {
    expect(isGapLongEnough(const Duration(seconds: 14)), false);
    expect(isGapLongEnough(const Duration(seconds: 15)), true);
    expect(isGapLongEnough(const Duration(hours: 3)), true);
    expect(isGapLongEnough(const Duration(hours: 3, seconds: 1)), false);
  });
  test('timestamp parsing preserves timezone and rejects ambiguous values', () {
    expect(
      ServerSession.parseTimestamp('2026-10-02 12:00:00.000+0900'),
      DateTime.utc(2026, 10, 2, 3).millisecondsSinceEpoch,
    );
    expect(ServerSession.parseTimestamp('2026-10-02 12:00:00'), isNull);
    expect(ServerSession.fromJson({}), isNull);
    expect(
      ServerSession.fromJson({
        'p': {'is': false},
      })?.running,
      false,
    );
  });
  test(
    'daily parser prioritizes authoritative total and avoids duplicate aliases',
    () async {
      final api = YptApi(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                's': true,
                'dl': {
                  'sm': 3600000,
                  'ad': 60000,
                  'ls': [
                    {'sb': '数学', 'sm': 3600000},
                  ],
                  'ss': [
                    {'sb': '数学', 'sm': 3600000},
                  ],
                },
                'ls': [
                  {'sb': '数学', 'sm': 3600000},
                ],
              }),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      final snap = await api.dayLogSubjects('2026-10-02');
      expect(snap.byTitle['数学'], 3600000);
      expect(snap.totalMs, 3660000);
    },
  );
  test(
    'business auth rejection is not parsed as an empty successful response',
    () async {
      final api = YptApi(
        client: MockClient(
          (_) async => http.Response('{"s":false,"c":"108"}', 200),
        ),
      );
      addTearDown(api.close);
      await expectLater(api.reloadInfo(), throwsA(isA<YptAuthException>()));
      await expectLater(
        api.dayLogSubjects('2026-10-02'),
        throwsA(isA<YptAuthException>()),
      );
    },
  );
  test(
    'hourglass renderer produces distinct, valid cached PNG frames',
    () async {
      final frames = await buildHourglassFrames();
      expect(frames, hasLength(20));
      expect(frames.toSet().length, greaterThan(15));
      for (final frame in frames) {
        expect(base64Decode(frame).take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      }
    },
  );
}
