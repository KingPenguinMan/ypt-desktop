import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ypt_api.dart';
import 'models.dart';
import 'social_auth.dart';
import 'timer_persistence.dart';
import 'gap_log.dart';
import 'history_models.dart';

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
  final YptApi api = YptApi();
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
  final TimerPersistence _timerStore = TimerPersistence();

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
  final GapLog _gapLog = GapLog();

  /// 当前空档的起始时间。有值且正在计时=false 时，表示"处于空档中"。
  ///
  /// 典型场景：停止计时后没有立刻开始新科目，用户去干别的事。这段时间
  /// 在手机版会弹窗询问"在做什么"，我们用 [pendingGap] 承载同一个语义。
  GapInterval? pendingGap;

  bool get hasPendingGap => pendingGap != null;

  /// 空档记录同步到服务端失败的提示。本地已保存,只是云端没成功。
  String? gapSyncErrorText;

  /// 当天已闭合的空档记录（供统计页与复盘页使用）。
  Future<List<GapInterval>> gapEntries() => _gapLog.todayEntries();

  /// 当天未计入学习时间的空档总时长。
  Future<Duration> gapDuration() => _gapLog.todayGapDuration();

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
      user = await api.reloadInfo();
      await _refreshSubjectTimesQuietly();
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
    if (api.jwt == null) return;
    historyLoading = true;
    historyErrorText = null;
    notifyListeners();

    // ── 1순위:批量 엔드포인트 ──
    final bulkOk = await _tryLoadHistoryBulk(days: days);
    if (bulkOk) {
      // 오늘은 앱 안에서 계산한 값이 정확하므로 덮어쓴다.
      history[todayStr()] = Duration(milliseconds: todayStudyMs);
      historyLoading = false;
      notifyListeners();
      return;
    }

    // ── 2순위: 날짜별 조회 ──
    final now = DateTime.now();
    final dates = <String>[];
    for (var i = 0; i < days; i++) {
      final d = now.subtract(Duration(days: i));
      dates.add(
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }

    int ok = 0;
    int failed = 0;
    // 한 번에 전부 쏘면 서버가 막을 수 있으므로 적당히 나눠서 보낸다.
    const chunk = 6;
    for (var i = 0; i < dates.length; i += chunk) {
      final batch = dates.sublist(i, min(i + chunk, dates.length));
      final results = await Future.wait(
        batch.map((d) => _fetchDayQuietly(d)),
      );
      for (final r in results) {
        if (r == null) {
          failed++;
        } else {
          history[r.key] = r.value;
          ok++;
        }
      }
      // 让出一点时间，避免连续打满。
      if (i + chunk < dates.length) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }

    // 오늘은 이미 앱 안에서 계산한 값이 있으므로 덮어쓴다.
    history[todayStr()] = Duration(milliseconds: todayStudyMs);

    if (ok == 0 && failed > 0) {
      historyErrorText = 'Could not load history';
    }
    historyLoading = false;
    notifyListeners();
  }

  /// 批量 엔드포인트로 히트맵을 채운다. 성공 여부만 반환.
  ///
  /// 응답 구조가 미확인이라 파서가 못 읽을 수 있다. 그럴 때 false 를 돌려
  /// 호출부가 날짜별 조회로 폴백하게 한다. 파싱은 [YptApi.parseCalendarPoints]
  /// 가 담당하며, "아무 날짜도 못 뽑았다"면 실패로 간주한다.
  Future<bool> _tryLoadHistoryBulk({required int days}) async {
    final now = DateTime.now();
    final start = now.subtract(Duration(days: days - 1));
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    // range/days 를 먼저 시도(범위가 명시적이므로 응답 형태가 더 단순할 확률이 높다).
    for (final attempt in <Future<List<CalendarPoint>> Function()>[
      () => api.rangeDays(fmt(start), fmt(now)),
      () => api.calendarHome(),
    ]) {
      try {
        final points = await attempt();
        if (points.isEmpty) continue;
        history.clear();
        for (final p in points) {
          history[p.date] = p.duration;
        }
        // 범위 밖 데이터가 섞여도 무해하므로 걸러내지 않는다.
        return true;
      } catch (e) {
        // 다음 시도로 넘어간다. 인증 실패면 그대로 내려가는 게 맞다.
        if (e is YptAuthException) rethrow;
        continue;
      }
    }
    return false;
  }

  Future<MapEntry<String, Duration>?> _fetchDayQuietly(String date) async {
    try {
      final snap = await api.dayLogSubjectsAuto(date);
      final total = snap.byId.values.fold<int>(0, (a, b) => a + b);
      return MapEntry(date, Duration(milliseconds: total));
    } catch (_) {
      return null;
    }
  }

  /// 선택된 날짜의 과목별 상세. 필요할 때만 요청한다.
  Future<void> selectDate(String date) async {
    selectedDate = date;
    notifyListeners();
    if (historySubjects.containsKey(date)) return;
    try {
      final snap = await api.dayLogSubjectsAuto(date);
      historySubjects[date] = snap.byTitle;
      notifyListeners();
    } catch (_) {
      historySubjects[date] = const {};
      notifyListeners();
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
    notifyListeners();
    try {
      user = await api.reloadInfo();
      await _refreshSubjectTimesQuietly(); // 과목별 오늘 시간
      // 登录成功后立刻恢复上次未结束的计时会话。必须在 user 拿到之后调用——
      // restoreTimer 要用 user.subjects 对齐科目名和颜色。
      await restoreTimer();
      // 同样恢复上次未闭合的空档，让"记录在做什么"的提示跨重启存活。
      pendingGap = await _gapLog.openGap();
    } catch (_) {
      api.jwt = null; // 만료/오류
      user = null;
      await sp.remove('jwt');
      // token 失效时不要留着会话快照——服务端已不认识这个用户了。
      await _timerStore.clear();
      await _gapLog.clearOpen();
    }
    loading = false;
    notifyListeners();
  }

  Future<bool> login(String email, String password) async {
    loading = true;
    errorText = null;
    notifyListeners();
    try {
      final res = await api.signIn(email, password);
      switch (res) {
        case SignInOk(:final data):
          user = data;
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

  Future<void> logout() async {
    // 必须先真正停掉服务端的会话再登出。silent 模式现在会发 /study/stop
    // （修复前它只是本地清空就返回，导致登出后服务端仍在累计时长）。
    await stopTimer(silent: true);
    final sp = await SharedPreferences.getInstance();
    await sp.remove('jwt');
    api.jwt = null;
    user = null;
    subjectTimesById = {};
    subjectTimes = {};
    myRank = null;
    ranks = [];
    groups = [];
    joinedGroups = [];
    errorText = null;
    timerErrorText = null;
    statsErrorText = null;
    groupsErrorText = null;
    // 登出后不应再挂着"待补录空档"，否则下一个登录的用户会看到上一位的记录。
    pendingGap = null;
    await _gapLog.clearOpen();
    await _timerStore.clear();
    notifyListeners();
  }

  /// 计时请求串行化。
  ///
  /// 原来的实现有个真实竞态：stopTimer 先本地清空、notifyListeners，然后才
  /// 发网络请求。这期间用户如果点了另一个科目，start 请求会和正在飞行的
  /// stop 请求交叉，服务端最终状态不可预测。
  ///
  /// 用一个 future 链当互斥锁：后到的操作必须等前一个完成。
  Future<void> _timerLock = Future<void>.value();

  T _serialize<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _timerLock = _timerLock.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> startTimer(Subject s) => _serialize(() => _startTimer(s));

  Future<void> _startTimer(Subject s) async {
    if (timerLoading) return;
    // 已���在计时则先停掉。stop 失败会抛异常，这里直接中断——不能让两个会话
    // 同时在服务端跑。
    if (studying) {
      final ok = await _stopTimerInternal();
      if (!ok) return;
    }

    // 若上次停止后有一个未记录的空档，在开始新会话前先闭合它。
    if (pendingGap != null && pendingGap!.isOpen) {
      final gap = pendingGap!;
      await _gapLog.commit(gap.copyWith(end: DateTime.now()));
      pendingGap = null;
    }

    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    timerLoading = true;
    timerErrorText = null;
    notifyListeners();
    try {
      await api.studyStart(s.title, taskId: null);
      activeSubject = s;
      _startedAtMs = startedAtMs;
      _startTicker();
      // 立刻落盘。必须在请求成功之后写——写早了会留下一个根本没发出去的
      // 会话快照，重启后去 stop 一个服务端不存在的会话。
      await _timerStore.save(TimerSnapshot(
        startedAtMs: startedAtMs,
        subjectId: s.id,
        subjectTitle: s.title,
        subjectColor: s.colorValue,
      ));
    } catch (e) {
      timerErrorText = 'Could not start timer: ${_readableError(e)}';
    }
    timerLoading = false;
    notifyListeners();
  }

  /// 用户点了停止。正常路径，会把空档记录挂起等下次开始时补录。
  Future<void> stopTimer({bool silent = false}) =>
      _serialize(() => _stopTimerInternal(silent: silent));

  /// 返回 true 表示确实停掉了（或本来就没在计时），false 表示失败。
  Future<bool> _stopTimerInternal({bool silent = false}) async {
    if (timerLoading && !silent) return false;
    final previousSubject = activeSubject;
    final started = _startedAtMs;
    if (previousSubject == null || started == null) {
      // 理论上不会发生：只要开始过就一定落过盘。发生说明存储被清了。
      // 此时仍要把 UI 和磁盘对齐，否则下次启动会拿不到会话。
      _clearTimer();
      await _timerStore.clear();
      notifyListeners();
      return true;
    }

    _clearTimer();
    // 本地状态先清（UI 立即响应），但**不能**提前清持久化——请求失败还要
    // 能回滚。等服务端确认后再清。
    if (silent) {
      // 静默模式用于退出登录。此时依然要把服务端的会话停掉，否则用户登出后
      // 服务端还在替他累计时长。修复前的实现在这里直接 return，是明确的 bug。
      try {
        await api.studyStop(started);
        await _timerStore.clear();
        user = await api.reloadInfo();
        await _refreshSubjectTimesQuietly();
      } catch (e) {
        // 登出场景下即使 stop 失败也不能拦住登出，但要把本地对齐到"未知
        // 状态"而不是谎称已停止——保留快照，下次启动会提示用户处理。
        timerErrorText = 'Could not stop timer on sign out: ${_readableError(e)}';
      }
      notifyListeners();
      return true;
    }

    // 停止后开启一个待补录的空档。用户在下次开始前会看到"这段时间在做什么"。
    final stoppedAt = DateTime.now();
    pendingGap = GapInterval(start: stoppedAt);
    await _gapLog.setOpen(pendingGap!);

    timerLoading = true;
    timerErrorText = null;
    notifyListeners();
    try {
      await api.studyStop(started);
      await _timerStore.clear();
      user = await api.reloadInfo(); // 오늘 총시간 갱신
      await _refreshSubjectTimesQuietly(); // 과목별 시간 갱신
      timerLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      // 回滚：把会话恢复成"正在计时"，并把快照写回磁盘。
      activeSubject = previousSubject;
      _startedAtMs = started;
      _startTicker();
      pendingGap = null;
      await _gapLog.clearOpen();
      await _timerStore.save(TimerSnapshot(
        startedAtMs: started,
        subjectId: previousSubject.id,
        subjectTitle: previousSubject.title,
        subjectColor: previousSubject.colorValue,
      ));
      timerErrorText = 'Could not stop timer: ${_readableError(e)}';
      timerLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 用户补录当前空档时选择/填写的内容。
  Future<void> describePendingGap({String? tag, String? activity}) async {
    final gap = pendingGap;
    if (gap == null) return;
    pendingGap = gap.copyWith(activity: activity, tag: tag);
    await _gapLog.setOpen(pendingGap!);
    notifyListeners();
  }

  /// 放弃当前空档记录（用户选择"不记了"）。
  Future<void> discardPendingGap() async {
    pendingGap = null;
    await _gapLog.clearOpen();
    notifyListeners();
  }

  /// 确认当前空档，闭合本地记录并同步到服务端 /rest/record。
  ///
  /// 官方客户端在停止计时后立即询问(`alert_stop_study_just_now_record`),
  /// 所以调用时机是"对话框点确定"那一刻，此时 startedAt/endedAt 都已确定。
  ///
  /// 云端失败**不阻塞**本地记录：这只是一个复盘辅助功能，失败了就退化为
  /// 本地记录，不该因此丢失数据或中断学习。
  Future<void> commitPendingGap() async {
    final gap = pendingGap;
    if (gap == null) return;
    // 用户点确定的那一刻作为空档结束时刻。
    final endedAt = DateTime.now();
    final closed = gap.copyWith(end: endedAt);
    await _gapLog.commit(closed);
    pendingGap = null;
    gapSyncErrorText = null;
    notifyListeners();

    // 已回答过的才上报：只是记录时长而无归类时，价值不大且会污染统计。
    if (!closed.isAnswered) return;
    try {
      await api.recordRest(
        startedAtMs: closed.start.millisecondsSinceEpoch,
        endedAtMs: endedAt.millisecondsSinceEpoch,
        tag: closed.tag,
      );
    } catch (e) {
      // 本地已保存,这里只提示云端没成功能。
      gapSyncErrorText =
          'Saved locally, but YPT server rejected it: ${_readableError(e)}';
      notifyListeners();
    }
  }

  /// 删除一条已闭合的空档（同时尝试删服务端记录）。
  Future<void> deleteGap(GapInterval gap) async {
    await _gapLog.remove(gap);
    notifyListeners();
    try {
      await api.deleteRest(startedAtMs: gap.start.millisecondsSinceEpoch);
    } catch (e) {
      // 服务端删不掉不影响本地,用户已经看到列表更新了。
      debugPrint('deleteRest failed: $e');
    }
  }

  /// 编辑已闭合空档的标签。
  Future<void> retagGap(GapInterval gap, String? tag) async {
    final updated = gap.copyWith(tag: tag);
    await _gapLog.update(updated);
    pendingGap = null;
    notifyListeners();
    try {
      await api.editRest(
        startedAtMs: updated.start.millisecondsSinceEpoch,
        tag: tag,
      );
    } catch (e) {
      gapSyncErrorText = 'Tag change not synced: ${_readableError(e)}';
      notifyListeners();
    }
  }

  /// 恢复上次会话（应用启动时调用）。
  ///
  /// 若磁盘上有快照，说明上次退出时服务端的 `/study/start` 已经发出去了。
  /// 这里重建 UI 上的计时显示，让用户看到"你之前在计时，点了停止"。
  Future<void> restoreTimer() async {
    final snap = await _timerStore.load();
    if (snap == null) return;

    // 尝试用服务端返回的 subjects 对齐科目信息，拿到正确的名字和颜色。
    var subject = user?.subjects.where((s) => s.id == snap.subjectId).firstOrNull;
    subject ??= user?.subjects
        .where((s) => s.title == snap.subjectTitle)
        .firstOrNull;
    subject ??= Subject(
      id: snap.subjectId,
      title: snap.subjectTitle,
      studyMs: 0,
      order: 0,
      colorValue: snap.subjectColor,
      archived: false,
    );

    activeSubject = subject;
    _startedAtMs = snap.startedAtMs;
    _startTicker();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _syncElapsed();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _syncElapsed();
      // 关键性能点：只通知"秒级监听者"，不广播全局。
      //
      // 原来的实现每秒 notifyListeners()，导致所有 context.watch<AppState>()
      // 的 widget 全部重建——包括群组列表、排行榜、统计图。现在 4 个 Tab
      // 挂在 IndexedStack 下（都处于存活状态），每秒重建整棵子树是纯浪费。
      //
      // 全局通知改由状态真正变化时（开始/停止/切科目/加载完成）触发。
      _tickListeners.forEach((l) => l());
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
    _tickListeners.clear();
    api.close();
    super.dispose();
  }
}
