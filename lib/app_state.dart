import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'server_session.dart';

import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ypt_api.dart';
import 'models.dart';
import 'social_auth.dart';
import 'social_credentials.dart';
import 'timer_persistence.dart';
import 'gap_log.dart';

/// 랭킹 조회 주기. wire 값은 API 의 `type` 파라미터에 그대로 실리는 문자열.
enum RankPeriod {
  day('day', 'Today'),
  week('week', 'Week'),
  month('month', 'Month');

  const RankPeriod(this.wire, this.label);

  /// 서버에 전달하는 type 값。
  final String wire;

  /// UI 표시용 라벨。
  final String label;
}

class AppState extends ChangeNotifier {
  final YptApi api;
  AppState({YptApi? api}) : api = api ?? YptApi();
  String? _accountKey;
  int _accountGeneration = 0;
  int _historyGeneration = 0;
  bool timerUncertain = false;
  bool _sessionReady = false;
  int gapRevision = 0;
  String? selectedDateError;
  bool selectedDateLoading = false;
  Timer? _reconcileTimer;
  String _day = todayStr();

  Future<void> _bindAccount(
    UserData data, {
    String? email,
    bool restoring = false,
  }) async {
    final sp = await SharedPreferences.getInstance();
    String? identity = data.accountId;
    final address = (data.email ?? email)?.trim().toLowerCase();
    if (identity == null && address != null && address.isNotEmpty) {
      identity = 'email:$address';
    }
    String? key = identity == null
        ? null
        : sha256.convert(utf8.encode(identity)).toString();
    // Existing installations may have a valid JWT but no account id/email
    // and no v2 local key yet. Use a stable token hash for migration instead
    // of blocking startup and hiding the account.
    key ??= api.jwt == null
        ? null
        : 'jwt:${sha256.convert(utf8.encode(api.jwt!)).toString()}';
    if (key == null && restoring) key = sp.getString('last_account_key_v2');
    if (key == null) throw const YptApiException('无法确认账号身份，未加载本地记录');
    if (key != _accountKey) {
      _accountGeneration++;
      _historyGeneration++;
      _clearTimer();
      history.clear();
      historySubjects.clear();
      selectedDate = null;
      selectedDateError = null;
      selectedDateLoading = false;
      historyLoading = false;
      historyErrorText = null;
      subjectTimes.clear();
      subjectTimesById.clear();
      pendingGap = null;
      gapSyncErrorText = null;
      _accountKey = key;
      _timerStore = TimerPersistence(key);
      _gapLog = GapLog(key);
      gapRevision++;
    }
    await sp.setString('last_account_key_v2', key);
    user = data;
    pendingGap = await _gapLog.openGap();
    await _applySession(data.session);
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!timerLoading && loggedIn) unawaited(reconcileTimer());
    });
  }

  Future<void> reconcileTimer() => _serialize<void>(() async {
    if (!loggedIn) return;
    try {
      final data = await api.reloadInfo();
      user = data;
      await _applySession(data.session);
      await _refreshSubjectTimesQuietly();
    } catch (e) {
      timerUncertain = true;
      timerErrorText = '等待服务端确认计时状态：${_readableError(e)}';
    }
    notifyListeners();
  });

  Future<void> _applySession(ServerSession? session) async {
    _sessionReady = session != null;
    if (session == null || (session.running && session.startedAtMs == null)) {
      timerUncertain = true;
      timerErrorText = '服务端未返回完整计时状态，请刷新后再操作';
      return;
    }
    timerUncertain = false;
    timerErrorText = null;
    if (!session.running) {
      _clearTimer();
      await _timerStore.clear();
      return;
    }
    final name = session.subject;
    final snap = await _timerStore.load();
    final sameSession = snap?.startedAtMs == session.startedAtMs;
    final title = name ?? (sameSession ? snap?.subjectTitle : null) ?? '正在学习';
    activeSubject =
        user?.subjects.where((s) => s.title == title).firstOrNull ??
        Subject(
          id: sameSession ? snap!.subjectId : 0,
          title: title,
          studyMs: 0,
          order: 0,
          colorValue: sameSession ? snap!.subjectColor : 0xFFE8552D,
          archived: false,
        );
    _startedAtMs = session.startedAtMs;
    _startTicker();
    await _timerStore.save(
      TimerSnapshot(
        startedAtMs: _startedAtMs!,
        subjectId: activeSubject!.id,
        subjectTitle: title,
        subjectColor: activeSubject!.colorValue,
      ),
    );
    if (pendingGap != null) {
      final end = DateTime.fromMillisecondsSinceEpoch(_startedAtMs!);
      final gap = pendingGap!;
      if (end.isAfter(gap.start) &&
          isGapLongEnough(end.difference(gap.start))) {
        await _gapLog.commit(gap.copyWith(end: end));
      } else {
        await _gapLog.clearOpen();
      }
      pendingGap = null;
      gapRevision++;
    }
  }

  UserData? user;
  bool loading = false;
  String? errorText;

  /// 타이머 상태
  Subject? activeSubject;
  int? _startedAtMs;
  Timer? _ticker;
  Duration elapsed = Duration.zero;
  bool timerLoading = false;
  String? timerErrorText;

  /// 计时会话本地持久化。startedAt 必须落盘，否则进程被杀后无法 stop。
  late TimerPersistence _timerStore;

  /// 秒级 UI 刷新订阅者。
  ///
  /// 与 ChangeNotifier 分开：计时数字每秒变，但其它状态不变。把"每秒刷新"
  /// 从全局广播里拆出来，避免整棵 widget 树每秒重建。
  final List<VoidCallback> _tickListeners = [];

  /// 订阅计时器的秒级刷新。返回取消函数。
  VoidCallback addTickListener(VoidCallback fn) {
    _tickListeners.add(fn);
    return () => _tickListeners.remove(fn);
  }

  /// 空档自述记录（停止计时 → 下次开始之间这段时间用户在做什么）。
  late GapLog _gapLog;

  /// 当前空档的起始时间。有值且正在计时=false 时，表示"处于空档中"。
  ///
  /// 典型场景：停止计时后没有立刻开始新科目，用户去干别的事。这段时间
  /// 在手机版会弹窗询问"在做什么"，我们用 [pendingGap] 承载同一个语义。
  GapInterval? pendingGap;

  bool get hasPendingGap => pendingGap != null;

  /// Local-only gap note. The unofficial client does not upload this data.
  String? gapSyncErrorText;

  /// 当天已闭合的空档记录（供统计页与复盘页使用）。
  Future<List<GapInterval>> gapEntries() => _accountKey == null
      ? Future.value([])
      : _gapLog.entriesFor(DateTime.now());

  /// 当天未计入学习时间的空档总时长。
  Future<Duration> gapDuration() => _accountKey == null
      ? Future.value(Duration.zero)
      : _gapLog.todayGapDuration();

  /// 导出今日空档记录为 CSV。
  Future<String> gapCsv() => _gapLog.toCsv();

  /// 常用活动标签，供 UI 直接渲染。
  List<String> get gapPresets => GapLog.presets;

  // 과목별 오늘 공부시간. /logs/day 응답이 비거나 제목 표기가 살짝 달라도
  // reload/info 의 subject 시간 값을 fallback으로 쓴다.
  Map<int, int> subjectTimesById = {};
  Map<String, int> subjectTimes = {};

  /// 오늘 총 공부시간 = 과목별 합(타이머+수동추가 포함, dl.sm+dl.ad와 일치).
  /// 과목별 데이터 없으면 dl.sm 폴백.
  int get todayStudyMs {
    if (subjectTimes.isNotEmpty) {
      return subjectTimes.values.fold(0, (a, b) => a + b);
    }
    return user?.dayLog?.studyMs ?? 0;
  }

  // 프로필/과목 재동기화 (새로고침 버튼용)
  bool profileLoading = false;

  Future<void> reloadProfile() async {
    if (api.jwt == null) return;
    profileLoading = true;
    errorText = null;
    notifyListeners();
    try {
      await reconcileTimer();
    } catch (e) {
      errorText = 'Could not load subjects: ${_readableError(e)}';
    }
    profileLoading = false;
    notifyListeners();
  }

  Future<void> refreshSubjectTimes() async {
    final loggedTimes = await api.dayLogSubjects(_currentLogDate());
    final mergedTimes = _mergedSubjectTimes(loggedTimes);
    subjectTimesById = mergedTimes.byId;
    subjectTimes = mergedTimes.byTitle;
    notifyListeners();
  }

  // 통계 상태
  int? myRank;
  List<RankMember> ranks = [];
  bool statsLoading = false;
  String? statsErrorText;

  /// 랭킹 주기. API 가 day/week/month 를 지원하므로 UI 에서 전환할 수 있다.
  /// (기존엔'hardcoded day' 로 고정돼 있었음)
  RankPeriod rankPeriod = RankPeriod.day;

  // 히스토리 상태 (달력 히트맵)
  /// 날짜(yyyy-MM-dd) → 그날 총 공부시간.
  final Map<String, Duration> history = {};

  /// 날짜 → 과목별 시간. 선택된 날짜의 상세가 필요할 때만 채워진다.
  final Map<String, Map<String, int>> historySubjects = {};

  bool historyLoading = false;
  String? historyErrorText;

  /// 열력에서 선택된 날짜. null 이면 오늘.
  String? selectedDate;

  Future<void> loadStats() async {
    if (user == null) return;
    statsLoading = true;
    statsErrorText = null;
    notifyListeners();
    // 각각 독립 실행 — 하나 실패해도 나머지는 로드(랭킹이 과목시간 실패에 막히지 않게)
    try {
      await refreshSubjectTimes();
    } catch (_) {}
    try {
      myRank = await api.myCategoryRank(user!.categoryId, user!.countryId);
    } catch (e) {
      statsErrorText = 'Could not load rank: ${_readableError(e)}';
    }
    try {
      ranks = await api.categoryRanks(
        user!.categoryId,
        user!.countryId,
        date: _rankDateFor(rankPeriod),
        type: rankPeriod.wire,
      );
    } catch (_) {}
    statsLoading = false;
    notifyListeners();
  }

  /// 랭킹 주기를 바꾸고 다시 불러온다.
  Future<void> setRankPeriod(RankPeriod p) async {
    if (rankPeriod == p) return;
    rankPeriod = p;
    statsLoading = true;
    notifyListeners();
    try {
      ranks = await api.categoryRanks(
        user!.categoryId,
        user!.countryId,
        date: _rankDateFor(p),
        type: p.wire,
      );
      statsErrorText = null;
    } catch (e) {
      statsErrorText = 'Could not load rank: ${_readableError(e)}';
    }
    statsLoading = false;
    notifyListeners();
  }

  /// 주기에 맞는 기준 날짜.
  ///
  /// day/ week 는 오늘 기준. month 는 해당 월 1일로 보내는 게服务端 관례지만,
  /// 정확한 규칙은 미확인이라 오늘을 그대로 보낸다(服务端가 알아서 처리).
  String _rankDateFor(RankPeriod p) {
    final now = DateTime.now();
    if (p == RankPeriod.month) {
      return '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    }
    return todayStr();
  }

  /// 달력 히트맵용 최근 N 일 데이터를 불러온다.
  ///
  /// 두 단계 전략:
  ///  1. RE 로 확인된批量 엔드포인트(`/logs/calendar/home`,
  ///     `/logs/range/days`)를 먼저 시도한다. 성공하면 요청 1~2 회로 끝난다.
  ///  2. 그쪽을 못 읽으면 날짜별로 1 회씩 보낸다(N 회). 실패해도 전체가
  ///     죽지 않게 하고 로딩 표시를 유지한다.
  ///
  /// [days] 는 2번 경로에서만 의미가 있다.
  Future<void> loadHistory({int days = 90}) async {
    if (!loggedIn) return;
    final generation = ++_historyGeneration;
    final account = _accountGeneration;
    historyLoading = true;
    historyErrorText = null;
    history.clear();
    historySubjects.clear();
    notifyListeners();
    int failed = 0;
    final now = DateTime.now();
    try {
      // Use the confirmed daily endpoint until bulk response fixtures are available.
      for (var i = 0; i < days; i += 3) {
        if (account != _accountGeneration || generation != _historyGeneration) {
          return;
        }
        final dates = [
          for (var n = i; n < min(i + 3, days); n++)
            _dateKey(DateTime(now.year, now.month, now.day - n)),
        ];
        final results = await Future.wait(
          dates.map((d) async {
            try {
              return MapEntry(d, await api.dayLogSubjects(d));
            } on YptAuthException {
              rethrow;
            } catch (_) {
              return null;
            }
          }),
        );
        if (account != _accountGeneration || generation != _historyGeneration) {
          return;
        }
        for (final r in results) {
          if (r == null) {
            failed++;
            continue;
          }
          history[r.key] = Duration(milliseconds: r.value.totalMs);
          historySubjects[r.key] = r.value.byTitle;
        }
        notifyListeners();
      }
      if (failed > 0) historyErrorText = '$failed 天加载失败，灰色未知日期不代表零学习';
    } catch (e) {
      if (account == _accountGeneration) historyErrorText = _readableError(e);
    } finally {
      if (account == _accountGeneration && generation == _historyGeneration) {
        historyLoading = false;
        notifyListeners();
      }
    }
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> selectDate(String date) async {
    selectedDate = date;
    selectedDateError = null;
    selectedDateLoading = true;
    notifyListeners();
    final account = _accountGeneration;
    try {
      final snap = await api.dayLogSubjects(date);
      if (account != _accountGeneration) return;
      historySubjects[date] = snap.byTitle;
      history[date] = Duration(milliseconds: snap.totalMs);
    } catch (e) {
      if (account == _accountGeneration && selectedDate == date) {
        selectedDateError = _readableError(e);
      }
    } finally {
      if (account == _accountGeneration && selectedDate == date) {
        selectedDateLoading = false;
        notifyListeners();
      }
    }
  }

  // 그룹 상태
  List<Group> groups = [];
  List<Group> joinedGroups = [];
  bool groupsLoading = false;
  String? groupsErrorText;

  Future<void> loadGroups() async {
    if (user == null) return;
    groupsLoading = true;
    groupsErrorText = null;
    notifyListeners();
    try {
      joinedGroups = await api.myGroups();
      groups = await api.browseGroups(user!.countryId);
    } catch (e) {
      groupsErrorText = 'Could not load groups: ${_readableError(e)}';
    }
    groupsLoading = false;
    notifyListeners();
  }

  Future<List<GroupMember>> fetchMembers(int groupId) =>
      api.groupMembers(groupId, user!.countryId);

  bool get loggedIn => user != null && api.jwt != null;
  bool get studying => activeSubject != null;

  int subjectStudyMs(Subject subject) {
    // 과목별 오늘 시간은 ls에 title로만 와서 byTitle에 있음. byId는 0 기본값이라
    // containsKey만 보면 0을 반환해 버림 → byId/byTitle 중 큰 값 채택.
    final byTitle = subjectTimes[_subjectKey(subject.title)] ?? 0;
    final byId = subject.id > 0 ? (subjectTimesById[subject.id] ?? 0) : 0;
    final best = byId > byTitle ? byId : byTitle;
    return best > 0 ? best : subject.studyMs;
  }

  static String todayStr() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _currentLogDate() {
    final date = user?.dayLog?.date.trim();
    if (date != null && date.length >= 10) return date.substring(0, 10);
    return todayStr();
  }

  Future<void> tryAutoLogin() async {
    final sp = await SharedPreferences.getInstance();
    final t = sp.getString('jwt');
    if (t == null || t.isEmpty) return;
    api.jwt = t;
    loading = true;
    errorText = null;
    notifyListeners();
    try {
      final data = await api.reloadInfo();
      await _bindAccount(data, restoring: true);
      await _refreshSubjectTimesQuietly();
    } on YptAuthException {
      api.jwt = null;
      user = null;
      await sp.remove('jwt');
      errorText = '登录已过期，请重新登录；本地记录已保留';
    } catch (e) {
      errorText = '暂时无法连接，登录凭证和本地记录已保留：${_readableError(e)}';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> login(String email, String password) async {
    loading = true;
    errorText = null;
    notifyListeners();
    try {
      final res = await api.signIn(email, password);
      switch (res) {
        case SignInOk(:final data):
          await _bindAccount(data, email: email);
          final sp = await SharedPreferences.getInstance();
          await sp.setString('jwt', data.jwt!);
          await _refreshSubjectTimesQuietly(); // 과목별 오늘 시간
          loading = false;
          notifyListeners();
          return true;
        case SignInError(:final code):
          errorText = errorMessage(code);
      }
    } catch (e) {
      errorText = 'Network error: ${_readableError(e)}';
    }
    loading = false;
    notifyListeners();
    return false;
  }

  /// 소셜 로그인 (Kakao/Naver): 시스템 브라우저 OAuth → YPT 교환 → jwt 저장.
  /// 반환: true=성공, false=실패/취소.
  Future<bool> socialLogin(SocialProvider provider) async {
    // 凭证通过构建参数注入，仓库里不含任何值（见 lib/social_credentials.dart）。
    // 未注入时直接给出可操作的错误，而不是发一个注定 401 的请求让用户猜。
    if (!SocialCredentials.isConfigured) {
      errorText =
          '社交登录未配置。请在构建时注入 ${provider.name} 的凭证：'
          'flutter build ... --dart-define=KAKAO_CLIENT_ID=... '
          '--dart-define=NAVER_CLIENT_ID=... --dart-define=NAVER_CLIENT_SECRET=...'
          '（Windows 用户可运行 build_and_test.bat，'
          '它会读取 social_credentials.local.bat）';
      notifyListeners();
      return false;
    }
    loading = true;
    errorText = null;
    notifyListeners();
    final auth = SocialAuth(provider);
    try {
      final cred = await auth.authenticate();
      final res = await api.socialSignIn(cred);
      switch (res) {
        case SignInOk(:final data):
          user = data;
          final sp = await SharedPreferences.getInstance();
          await sp.setString('jwt', data.jwt!);
          // sign-up-jwt 응답은 과목(ss)을 비워 줄 수 있어 전체 데이터로 동기화
          try {
            user = await api.reloadInfo();
          } catch (_) {}
          await _bindAccount(user!);
          await _refreshSubjectTimesQuietly();
          loading = false;
          notifyListeners();
          return true;
        case SignInError(:final code):
          errorText = errorMessage(code);
      }
    } on SocialAuthCancelled {
      // 사용자가 로그인 안 함(취소/타임아웃) — 조용히 무시
    } catch (e) {
      errorText = '${provider.name} login failed: ${_readableError(e)}';
    } finally {
      auth.close();
    }
    loading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() => _serialize<void>(() async {
    if (timerUncertain || !_sessionReady) {
      try {
        user = await api.reloadInfo();
        await _applySession(user!.session);
      } catch (e) {
        timerErrorText = '无法确认停止状态，尚未退出：${_readableError(e)}';
        notifyListeners();
        return;
      }
    }
    if (timerUncertain || !await _stopTimerInternal(silent: true)) return;
    final sp = await SharedPreferences.getInstance();
    await sp.remove('jwt');
    await sp.remove('last_account_key_v2');
    _reconcileTimer?.cancel();
    _accountGeneration++;
    _historyGeneration++;
    api.jwt = null;
    user = null;
    _accountKey = null;
    _sessionReady = false;
    timerUncertain = false;
    subjectTimesById = {};
    subjectTimes = {};
    history.clear();
    historySubjects.clear();
    selectedDate = null;
    selectedDateError = null;
    selectedDateLoading = false;
    historyLoading = false;
    historyErrorText = null;
    myRank = null;
    ranks = [];
    groups = [];
    joinedGroups = [];
    pendingGap = null;
    gapSyncErrorText = null;
    gapRevision++;
    errorText = null;
    timerErrorText = null;
    statsErrorText = null;
    groupsErrorText = null;
    notifyListeners();
  });

  /// 计时请求串行化。
  ///
  /// 原来的实现有个真实竞态：stopTimer 先本地清空、notifyListeners，然后才
  /// 发网络请求。这期间用户如果点了另一个科目，start 请求会和正在飞行的
  /// stop 请求交叉，服务端最终状态不可预测。
  ///
  /// 用一个 future 链当互斥锁：后到的操作必须等前一个完成。
  Future<void> _timerLock = Future<void>.value();

  /// 把 [op] 排进计时操作队列，返回它完成后的结果。
  ///
  /// 用 future 链当互斥锁：后到的操作必须等前一个完成（无论前一个成功还是
  /// 失败）。注意不能写成 `T _serialize(...)`——那样返回类型与
  /// `completer.future` 冲突，编译器会报 return_of_invalid_type。
  Future<T> _serialize<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _timerLock = _timerLock
        .then((_) async {
          try {
            completer.complete(await op());
          } catch (e, st) {
            completer.completeError(e, st);
          }
          // 链本身必须吞掉异常，否则一次失败会让后续所有操作都跳过。
        })
        .catchError((Object _) {
          // no-op：调用方的错误已通过 completer 传出。
        });
    return completer.future;
  }

  Future<void> startTimer(Subject s) => _serialize<void>(() => _startTimer(s));

  Future<void> _startTimer(Subject s) async {
    if (!loggedIn) return;
    timerLoading = true;
    timerErrorText = null;
    notifyListeners();
    try {
      // Reconcile before every mutation: another device may have stopped/switched.
      user = await api.reloadInfo();
      await _applySession(user!.session);
      if (timerUncertain) return;
      if (studying && !await _stopTimerInternal(silent: true)) return;
      timerLoading = true;
      final session = await api.studyStart(s.title);
      if (session != null) {
        await _applySession(session);
      } else {
        user = await api.reloadInfo();
        await _applySession(user!.session);
      }
    } catch (e) {
      // A timeout may have happened AFTER the server accepted the request.
      timerUncertain = true;
      timerErrorText = '开始结果待确认，请刷新：${_readableError(e)}';
    } finally {
      timerLoading = false;
      notifyListeners();
    }
  }

  /// 用户点了停止。正常路径，会把空档记录挂起等下次开始时补录。
  ///
  /// 内部返回 bool（是否真的停掉了），但这里故意丢弃——调用方只看
  /// 状态变化，不需要成功标志。要判断成功请用 [stopTimerAndReport]。
  Future<void> stopTimer({bool silent = false}) =>
      _serialize<void>(() => _stopTimerInternal(silent: silent)).then((_) {});

  /// 同 [stopTimer]，但返回是否真的停掉了。
  Future<bool> stopTimerAndReport({bool silent = false}) =>
      _serialize<bool>(() => _stopTimerInternal(silent: silent));

  /// 返回 true 表示确实停掉了（或本来就没在计时），false 表示失败。
  Future<bool> _stopTimerInternal({bool silent = false}) async {
    if (!loggedIn) return true;
    timerLoading = true;
    timerErrorText = null;
    notifyListeners();
    try {
      user = await api.reloadInfo();
      await _applySession(user!.session);
      if (timerUncertain) return false;
      final started = _startedAtMs;
      if (!studying || started == null) return true;
      final result = await api.studyStop(started);
      // From this point onwards the stop is committed. Never resurrect it if
      // a disk write or profile refresh fails.
      _clearTimer();
      timerUncertain = false;
      if (result != null) {
        history[result.date] = Duration(
          milliseconds: result.studyMs + result.addedMs,
        );
      }
    } catch (e) {
      timerUncertain = true;
      timerErrorText = '停止结果待确认，已保留恢复数据：${_readableError(e)}';
      return false;
    } finally {
      timerLoading = false;
      notifyListeners();
    }
    try {
      await _timerStore.clear();
      if (!silent) {
        pendingGap = GapInterval(start: DateTime.now());
        await _gapLog.setOpen(pendingGap!);
        gapRevision++;
      }
    } catch (e) {
      timerErrorText = '已停止，但本地保存失败：${_readableError(e)}';
    }
    try {
      user = await api.reloadInfo();
      await _refreshSubjectTimesQuietly();
    } catch (e) {
      timerErrorText = '已停止，统计稍后刷新：${_readableError(e)}';
    }
    notifyListeners();
    return true;
  }

  /// 用户补录当前空档时选择/填写的内容。
  Future<void> describePendingGap({String? tag, String? activity}) async {
    final gap = pendingGap;
    if (gap == null) return;
    pendingGap = GapInterval(
      start: gap.start,
      end: gap.end,
      activity: activity,
      tag: tag,
    );
    await _gapLog.setOpen(pendingGap!);
    notifyListeners();
  }

  /// 放弃当前空档记录（用户选择"不记了"）。
  Future<void> discardPendingGap() async {
    pendingGap = null;
    await _gapLog.clearOpen();
    notifyListeners();
  }

  /// Close and save the gap locally. The official rest endpoint has not been
  /// verified, so this client deliberately does not send a guessed request.
  Future<void> commitPendingGap() async {
    final gap = pendingGap;
    if (gap == null) return;
    final closed = gap.copyWith(end: DateTime.now());
    await _gapLog.commit(closed);
    pendingGap = null;
    gapRevision++;
    gapSyncErrorText = null;
    notifyListeners();
  }

  Future<void> updateGapLabel(
    GapInterval gap, {
    String? tag,
    String? activity,
  }) async {
    final trimmed = activity?.trim();
    await _gapLog.update(
      GapInterval(
        start: gap.start,
        end: gap.end,
        tag: tag,
        activity: trimmed == null || trimmed.isEmpty ? null : trimmed,
      ),
    );
    gapRevision++;
    notifyListeners();
  }

  Future<void> deleteGap(GapInterval gap) async {
    await _gapLog.remove(gap);
    gapRevision++;
    notifyListeners();
  }

  Future<void> restoreTimer() => reconcileTimer();

  void _startTicker() {
    _ticker?.cancel();
    _syncElapsed();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncElapsed();
      if (_day != todayStr()) {
        _day = todayStr();
        subjectTimes.clear();
        subjectTimesById.clear();
        historySubjects.remove(_day);
        unawaited(reconcileTimer());
      }
      // 关键性能点：只通知"秒级监听者"，不广播全局。
      //
      // 原来的实现每秒 notifyListeners()，导致所有 context.watch<AppState>()
      // 的 widget 全部重建——包括群组列表、排行榜、统计图。现在 4 个 Tab
      // 挂在 IndexedStack 下（都处于存活状态），每秒重建整棵子树是纯浪费。
      //
      // 全局通知改由状态真正变化时（开始/停止/切科目/加载完成）触发。
      //
      // 用 for 循环而非 forEach：监听者可能在回调里取消订阅（dispose 时会），
      // 迭代同一个 List 时会抛 ConcurrentModificationError。复制一份再遍历
      // 同样安全，但 for 循环更省一次分配。
      for (final l in List<VoidCallback>.of(_tickListeners)) {
        l();
      }
    });
  }

  void _syncElapsed() {
    final started = _startedAtMs;
    if (started == null) {
      elapsed = Duration.zero;
      return;
    }
    final current = DateTime.now().millisecondsSinceEpoch - started;
    elapsed = Duration(milliseconds: current < 0 ? 0 : current);
  }

  void _clearTimer() {
    _ticker?.cancel();
    _ticker = null;
    activeSubject = null;
    _startedAtMs = null;
    elapsed = Duration.zero;
  }

  Future<void> _refreshSubjectTimesQuietly() async {
    try {
      await refreshSubjectTimes();
    } catch (_) {}
  }

  SubjectTimeSnapshot _mergedSubjectTimes(SubjectTimeSnapshot loggedTimes) {
    final byId = <int, int>{};
    final byTitle = <String, int>{};

    void merge(SubjectTimeSnapshot snapshot) {
      for (final entry in snapshot.byId.entries) {
        if (entry.value > 0 || !byId.containsKey(entry.key)) {
          byId[entry.key] = entry.value;
        }
      }
      for (final entry in snapshot.byTitle.entries) {
        final key = _subjectKey(entry.key);
        if (entry.value > 0 || !byTitle.containsKey(key)) {
          byTitle[key] = entry.value;
        }
      }
    }

    for (final subject in user?.subjects ?? const <Subject>[]) {
      if (subject.id > 0) byId[subject.id] = subject.studyMs;
      byTitle[_subjectKey(subject.title)] = subject.studyMs;
    }
    final dayLogTimes = user?.dayLog?.subjectTimes;
    if (dayLogTimes != null) merge(dayLogTimes);
    merge(loggedTimes);
    return SubjectTimeSnapshot(byId: byId, byTitle: byTitle);
  }

  static String _subjectKey(String title) =>
      title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static String _readableError(Object e) {
    final text = e.toString();
    if (text.startsWith('TimeoutException')) return 'request timed out';
    // 소셜 네이티브 인터셉터 미구현 플랫폼(현재 Windows/macOS)
    if (text.startsWith('MissingPluginException')) {
      return 'not supported on this platform yet';
    }
    if (text.startsWith('Exception: ')) return text.substring(11);
    return text;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _reconcileTimer?.cancel();
    _tickListeners.clear();
    api.close();
    super.dispose();
  }
}
