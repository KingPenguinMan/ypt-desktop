import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'social_auth.dart';

/// YPT API 클라이언트. RE 스펙(YPT_API_SPEC_FINAL.md) 기반.
/// base=https://pi.tgclab.com, 인증=Authorization: JWT <token>.
class YptApi {
  static const String base = 'https://pi.tgclab.com';
  static const Duration requestTimeout = Duration(seconds: 15);

  // 실제 앱과 동일하게 보이도록 — 안드로이드 기기 모델 + dart:io UA.
  // (실제 앱은 Build.MODEL 과 Dart/<버전> (dart:io) 를 보낸다.)
  static const String deviceModel = 'SM-S921N'; // Galaxy S24 (흔한 한국 모델)
  static const String userAgent = 'Dart/3.11 (dart:io)';

  final http.Client _client;
  String? jwt;

  YptApi({http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> _headers({bool auth = true}) => {
        'Content-Type': 'application/json',
        'Accept-Encoding': 'gzip',
        'User-Agent': userAgent, // 실제 앱과 동일 (Dart/3.11 dart:io)
        if (auth && jwt != null) 'authorization': 'JWT $jwt',
      };

  Uri _u(String path) => Uri.parse('$base$path');

  Future<http.Response> _get(String path) =>
      _client.get(_u(path), headers: _headers()).timeout(requestTimeout);

  Future<http.Response> _post(
    String path,
    Map<String, Object?> body, {
    bool auth = true,
  }) =>
      _client
          .post(_u(path), headers: _headers(auth: auth), body: jsonEncode(body))
          .timeout(requestTimeout);

  Map<String, dynamic> _decodeObject(http.Response r) {
    final decoded = jsonDecode(utf8.decode(r.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('Expected a JSON object response.');
  }

  void _ensureOk(http.Response r, String endpoint) {
    if (r.statusCode != 200) {
      throw YptApiException('$endpoint HTTP ${r.statusCode}');
    }
  }

  void close() {
    _client.close();
  }

  /// POST /user/sign-in-jwt — 이메일 로그인. 성공 시 jwt 저장.
  Future<SignInResult> signIn(String email, String password) async {
    final r = await _post(
        '/user/sign-in-jwt',
        {
          'email': email,
          'password': password,
          'loginProvider': 'Email',
          'new': true,
          'getx': true,
          'language': 'en',
        },
        auth: false);
    if (r.statusCode != 200) return SignInError('http_${r.statusCode}');
    final j = _decodeObject(r);
    if (j['s'] == true) {
      final token = j['jwt']?.toString();
      if (token == null || token.isEmpty) return SignInError('missing_jwt');
      jwt = token;
      return SignInOk(UserData.fromJson(j));
    }
    return SignInError(j['c']?.toString() ?? 'unknown');
  }

  /// POST /user/social/sign-up-jwt — 소셜 로그인/가입(멱등). 성공 시 jwt 저장.
  /// 실제 앱과 동일 바디: {accessToken, providerId, email, loginProvider, new, getx, version}.
  /// providerId가 신규면 가입, 기존이면 그 계정으로 로그인 (RE: spec/SOCIAL_LOGIN.md).
  Future<SignInResult> socialSignIn(SocialCredential cred) async {
    final r = await _post(
        '/user/social/sign-up-jwt',
        {
          'accessToken': cred.accessToken,
          'providerId': cred.providerId,
          'email': cred.email,
          'loginProvider': cred.loginProvider,
          'new': true,
          'getx': true,
          'version': 810046,
        },
        auth: false);
    if (r.statusCode != 200) return SignInError('http_${r.statusCode}');
    final j = _decodeObject(r);
    if (j['s'] == true) {
      final token = j['jwt']?.toString();
      if (token == null || token.isEmpty) return SignInError('missing_jwt');
      jwt = token;
      return SignInOk(UserData.fromJson(j));
    }
    return SignInError(j['c']?.toString() ?? 'unknown');
  }

  /// POST /user/v2/reload/info — 프로필/과목/오늘로그 갱신.
  /// 실제 앱과 동일: cd 값을 전부 null로 보내야 전체 데이터(ss 등)를 받는다.
  /// (오래된 타임스탬프를 보내면 델타만 와서 과목이 빠짐 — 캡처로 확인)
  Future<UserData> reloadInfo() async {
    final r = await _post('/user/v2/reload/info', {
      'pv': 0,
      'cd': {
        'su': null,
        'sbu': null,
        'cu': null,
        'eu': null,
        'du': null,
        'tu': null,
      },
    });
    _ensureOk(r, 'reload/info');
    return UserData.fromJson(_decodeObject(r));
  }

  /// GET /logs/my-category-rank — 내 카테고리 등수. 응답 {s, mr}.
  Future<int?> myCategoryRank(int categoryId, int countryId) async {
    final r = await _get(
        '/logs/my-category-rank?category_id=$categoryId&country_id=$countryId');
    _ensureOk(r, 'logs/my-category-rank');
    final j = _decodeObject(r);
    if (j['s'] == true) return intOrNull(j['mr']);
    return null;
  }

  /// GET /logs/category/member/ranks — 카테고리 랭킹 멤버 (type=day/week/month).
  /// 응답 {s, ms:[{n,sd,ud,si,...}], tc}. sd=공부ms, n=닉네임, si=studiconID.
  Future<List<RankMember>> categoryRanks(int categoryId, int countryId,
      {String type = 'day', int page = 1, required String date}) async {
    final r = await _get(
        '/logs/category/member/ranks?date=$date&categoryID=$categoryId&countryID=$countryId&page=$page&type=$type');
    _ensureOk(r, 'logs/category/member/ranks');
    final j = _decodeObject(r);
    final ms = j['ms'] is List ? j['ms'] as List : const [];
    return ms
        .whereType<Map<String, dynamic>>()
        .map(RankMember.fromJson)
        .toList();
  }

  /// GET /logs/day?date= — 오늘 과목별 공부시간 (dayLog.ls).
  /// API 버전에 따라 과목 식별자가 제목 또는 id 계열 키로 내려올 수 있다.
  ///
  ///date 파라미터로 과거 날짜도 지정할 수 있다(달력 히트맵의 데이터 소스).
  /// 형식은 `YYYY-MM-DD`. 응답 403은 인증 만료이므로 예외로 변환한다.
  Future<SubjectTimeSnapshot> dayLogSubjects(String date) async {
    final r = await _get('/logs/day?date=$date');
    if (r.statusCode == 403) {
      throw const YptAuthException('session expired');
    }
    _ensureOk(r, 'logs/day');
    return _parseDayLogSnapshot(_decodeObject(r));
  }

  /// GET /logs/v2/day?date= — 위와 같은 데이터를 v2 엔드포인트에서 시도.
  ///
  /// 2026-10-02 실측 + RE(libapp.so v810.0.85)결과:
  ///  - 이 경로는 **서버에는 존재**(404 아닌 200 + `{"s":false,"c":"108"}`)
  ///  - 그러나 공식 클라이언트의 문자열 테이블에는 **등장하지 않는다**
  ///  →遗留 엔드포인트로 보인다. 필드 구조가 v1 과 다를 수 있으므로
  ///    최후의 폴백으로만 쓴다.
  ///
  /// 공식 클라이언트가 실제로 쓰는 확정 엔드포인트는:
  ///   GET /logs/day?date=       단일 날짜
  ///   GET /logs/range/days      기간 범위(히트맵 批量 조회에 적합)
  ///   GET /logs/calendar/home   달력 요약
  Future<SubjectTimeSnapshot> dayLogSubjectsV2(String date) async {
    final r = await _get('/logs/v2/day?date=$date');
    if (r.statusCode == 403) {
      throw const YptAuthException('session expired');
    }
    _ensureOk(r, 'logs/v2/day');
    return _parseDayLogSnapshot(_decodeObject(r));
  }

  /// 공식 엔드포인트(/logs/day) 우선, 실패하면遗留 v2 로 폴백.
  Future<SubjectTimeSnapshot> dayLogSubjectsAuto(String date) async {
    try {
      return await dayLogSubjects(date);
    } catch (e) {
      if (e is YptAuthException) rethrow; // 인증 문제면 폴백해도 소용없다
      try {
        return await dayLogSubjectsV2(date);
      } catch (_) {
        rethrow; // 둘 다 실패 → 진짜 오류
      }
    }
  }

  /// /logs/day 계열 응답을 SubjectTimeSnapshot 으로 변환.
  ///
  /// 두 응답 위치(dl 안과 최상위)를 모두 합치는 이유:과목 식별자가 어느 한쪽에만
  /// 내려오는 버전 차이가 관측되어 있다.
  SubjectTimeSnapshot _parseDayLogSnapshot(Map<String, dynamic> j) {
    final dl = j['dl'];
    final subjectBooks = mapListValue(j['sbs']);
    final titleByIndex = <int, String>{};
    for (var i = 0; i < subjectBooks.length; i++) {
      final title = firstStringValue(subjectBooks[i], const ['t', 'title']);
      if (title != null && title.trim().isNotEmpty) titleByIndex[i] = title;
    }

    final byId = <int, int>{};
    final byTitle = <String, int>{};

    void merge(SubjectTimeSnapshot snapshot) {
      for (final entry in snapshot.byId.entries) {
        byId[entry.key] = (byId[entry.key] ?? 0) + entry.value;
      }
      for (final entry in snapshot.byTitle.entries) {
        byTitle[entry.key] = (byTitle[entry.key] ?? 0) + entry.value;
      }
    }

    if (dl is Map<String, dynamic>) {
      merge(subjectTimeSnapshotFromJson(dl, titleByIndex: titleByIndex));
    }
    merge(subjectTimeSnapshotFromJson(j, titleByIndex: titleByIndex));
    return SubjectTimeSnapshot(byId: byId, byTitle: byTitle);
  }

  /// GET /group/list-new-2 — 둘러보기(신규) 그룹 목록. 응답 {s, gs:[...]}.
  Future<List<Group>> browseGroups(int countryId, {int page = 1}) async {
    final r = await _get(
        '/group/list-new-2?category_id=0&order_type=promotedAt&only_available=false&only_open=false&only_cam=false&page=$page&country_id=$countryId&p=true');
    _ensureOk(r, 'group/list-new-2');
    final j = _decodeObject(r);
    final gs = j['gs'] is List ? j['gs'] as List : const [];
    return gs.whereType<Map<String, dynamic>>().map(Group.fromJson).toList();
  }

  /// GET /group/groups/v2 — 내가 속한 그룹. 응답 {s, gs, ms, cs, ps} 4개 배열에 분산.
  Future<List<Group>> myGroups() async {
    final r = await _get('/group/groups/v2');
    _ensureOk(r, 'group/groups/v2');
    final j = _decodeObject(r);
    final out = <Group>[];
    final seen = <int>{};
    for (final key in ['gs', 'ms', 'cs', 'ps']) {
      final list = j[key] is List ? j[key] as List : const [];
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final g = Group.fromJson(item);
        if (g.title.isNotEmpty && seen.add(g.id)) out.add(g);
      }
    }
    return out;
  }

  /// GET /logs/group/members/v2 — 그룹 멤버(공부 현황). 응답 {s, ms:[...]}.
  Future<List<GroupMember>> groupMembers(int groupId, int countryId) async {
    final r = await _get(
        '/logs/group/members/v2?groupID=$groupId&countryID=$countryId&isLooking=true&version=810046');
    _ensureOk(r, 'logs/group/members/v2');
    final j = _decodeObject(r);
    final ms = j['ms'] is List ? j['ms'] as List : const [];
    return ms
        .whereType<Map<String, dynamic>>()
        .map(GroupMember.fromJson)
        .toList();
  }

  /// POST /study/start — 타이머 시작. 응답에 dayLog 포함.
  Future<DayLog?> studyStart(String subject, {int? taskId}) async {
    final r = await _post('/study/start',
        {'subject': subject, 'deviceModel': deviceModel, 'taskId': taskId});
    _ensureOk(r, 'study/start');
    final j = _decodeObject(r);
    if (j['s'] == true && j['dl'] is Map<String, dynamic>) {
      return DayLog.fromJson(j['dl']);
    }
    throw YptApiException(j['c']?.toString() ?? 'study/start failed');
  }

  /// POST /study/stop — 타이머 정지. startedAt=시작 epoch(ms).
  Future<DayLog?> studyStop(int startedAtMs) async {
    final r = await _post(
        '/study/stop', {'startedAt': startedAtMs, 'deviceModel': deviceModel});
    _ensureOk(r, 'study/stop');
    final j = _decodeObject(r);
    if (j['s'] == true && j['dl'] is Map<String, dynamic>) {
      return DayLog.fromJson(j['dl']);
    }
    throw YptApiException(j['c']?.toString() ?? 'study/stop failed');
  }

  // ─────────────────────────────────────────────────────────────
  // 休息记录(rest) — 官方客户端存在完整的"停止计时后询问这段时间在做什么"
  // 功能。端点与字段名由官方 APK(libapp.so, v810.0.85)逆向确认,并已实测
  // 这些端点在生产服务上返回 200(鉴权拦截),不是 404。
  //
  // UI 流程由 i18n key 还原:
  //   study_dialog_rest_title → study_dialog_rest_record
  //   → study_dialog_rest_edit_tag / study_dialog_rest_skip
  //   标签选择:study_break_tag_selection / select_break_tag_msg
  //   标签不存在:study_break_tag_not_exist_alert
  //   离线别名:alert_stop_study_just_now_record(即停止后立即询问)
  // ─────────────────────────────────────────────────────────────

  /// POST /rest/record — 登记一条休息记录。
  ///
  /// 字段名从二进制中确认存在:`tag` / `startedAt` / `endedAt` / `minutes`。
  /// 语义:`startedAt`=休息开始(即上次停止计时的时刻),`endedAt`=休息结束
  /// (即本次开始计时的时刻)。手机版在停止后立即弹窗,所以这两个值在
  /// 弹窗那一刻都已确定(endedAt 取弹窗确认的时刻)。
  ///
  /// [tag] 传 null 表示只登记时长、不做归类(对应「先不填标签」)。
  Future<void> recordRest({
    required int startedAtMs,
    required int endedAtMs,
    String? tag,
  }) async {
    final r = await _post('/rest/record', {
      'startedAt': startedAtMs,
      'endedAt': endedAtMs,
      'minutes': (endedAtMs - startedAtMs) ~/ 60000,
      if (tag != null) 'tag': tag,
      'deviceModel': deviceModel,
    });
    _ensureOk(r, 'rest/record');
    final j = _decodeObject(r);
    if (j['s'] != true) {
      throw YptApiException(j['c']?.toString() ?? 'rest/record failed');
    }
  }

  /// POST /rest/add — 补记一条休息记录(用于历史补录场景)。
  Future<void> addRest({
    required int startedAtMs,
    required int endedAtMs,
    String? tag,
  }) async {
    final r = await _post('/rest/add', {
      'startedAt': startedAtMs,
      'endedAt': endedAtMs,
      'minutes': (endedAtMs - startedAtMs) ~/ 60000,
      if (tag != null) 'tag': tag,
      'deviceModel': deviceModel,
    });
    _ensureOk(r, 'rest/add');
    final j = _decodeObject(r);
    if (j['s'] != true) {
      throw YptApiException(j['c']?.toString() ?? 'rest/add failed');
    }
  }

  /// POST /rest/edit — 修改已登记的休息记录。
  Future<void> editRest({
    required int startedAtMs,
    int? endedAtMs,
    String? tag,
  }) async {
    final r = await _post('/rest/edit', {
      'startedAt': startedAtMs,
      if (endedAtMs != null) 'endedAt': endedAtMs,
      if (tag != null) 'tag': tag,
      'deviceModel': deviceModel,
    });
    _ensureOk(r, 'rest/edit');
    final j = _decodeObject(r);
    if (j['s'] != true) {
      throw YptApiException(j['c']?.toString() ?? 'rest/edit failed');
    }
  }

  /// POST /rest/delete — 删除一条休息记录。
  Future<void> deleteRest({required int startedAtMs}) async {
    final r = await _post('/rest/delete', {
      'startedAt': startedAtMs,
      'deviceModel': deviceModel,
    });
    _ensureOk(r, 'rest/delete');
    final j = _decodeObject(r);
    if (j['s'] != true) {
      throw YptApiException(j['c']?.toString() ?? 'rest/delete failed');
    }
  }

  /// POST /rest/tags/edit — 修改休息记录的标签。
  ///
  /// 官方客户端把标签做成可编辑(`study_rest_tag_title`、
  /// `study_rest_tag_dialog_title` 等 i18n key 表明标签是用户自定义的),
  /// 所以标签集合应当从服务端拉取而非本地硬编码。
  Future<void> editRestTag({
    String? original,
    required String tag,
  }) async {
    final r = await _post('/rest/tags/edit', {
      if (original != null) 'original': original,
      'tag': tag,
      'deviceModel': deviceModel,
    });
    _ensureOk(r, 'rest/tags/edit');
    final j = _decodeObject(r);
    if (j['s'] != true) {
      throw YptApiException(j['c']?.toString() ?? 'rest/tags/edit failed');
    }
  }

  /// POST /study/sync-offline-data — 离线记录的补传。
  ///
  /// 官方支持离线记录(存在 `OFFLINE_POMODORO_START_LOG` /
  /// `OFFLINE_POMODORO_STOP_LOG` 等持久化 key 与
  /// `study/sync-offline-data` 端点)。本客户端目前不做离线记录,
  /// 保留此方法以备将来实现时使用。
  Future<void> syncOfflineData(Map<String, Object?> payload) async {
    final r = await _post('/study/sync-offline-data', payload);
    _ensureOk(r, 'study/sync-offline-data');
  }

  // ─────────────────────────────────────────────────────────────
  // 히트맵용 批量 조회 — RE 로 확인된 공식 엔드포인트.
  //
  // 앞의 dayLogSubjectsAuto 는 날짜마다 1 회씩 호출하므로 90 일이면 90 회다.
  // 공식 클라이언트에게는 /logs/range/days(기간 범위)와
  // /logs/calendar/home(달력 요약)이 있으므로, 히트맵은 이쪽을 쓰는 게
  // 훨씬 적다. 응답 구조는 미확인이라 관용적 파서를 쓴다.
  // ─────────────────────────────────────────────────────────────

  /// GET /logs/calendar/home — 달력 요약. 히트맵에 한 번의 요청으로 충분할
  /// 가능성 높음(파라미터 없음).
  ///
  /// 응답 필드 구조는 RE 로 확정할 수 없다(문자열 테이블에 필드명이 없음).
  /// 그래서 [CalendarPoint] 목록으로 관용 파싱하고, 못 읽으면 빈 리스트를
  /// 돌려준다(호출부가 폴백 처리).
  Future<List<CalendarPoint>> calendarHome() async {
    final r = await _get('/logs/calendar/home');
    if (r.statusCode == 403) {
      throw const YptAuthException('session expired');
    }
    if (r.statusCode != 200) return const [];
    final j = _decodeObject(r);
    return parseCalendarPoints(j);
  }

  /// GET /logs/range/days — 기간 범위 조회.
  Future<List<CalendarPoint>> rangeDays(
    String startDate,
    String endDate, {
    String? groupId,
  }) async {
    final q = StringBuffer('/logs/range/days?start=$startDate&end=$endDate');
    if (groupId != null) q.write('&groupID=$groupId');
    final r = await _get(q.toString());
    if (r.statusCode == 403) {
      throw const YptAuthException('session expired');
    }
    if (r.statusCode != 200) return const [];
    return parseCalendarPoints(_decodeObject(r));
  }

  /// 달력/범위 응답의 관용 파서.
  ///
  /// 이 엔드포인트들의 응답은 미확인이라, "날짜로 보이는 키 + ms로 보이는 값"
  /// 을 아무 데서나 찾아낸다. `date`/`dt`/`d` 키를 날짜로, `sm`/`ms`/`studyMs`
  /// 를 시간(ms)으로 인식한다. 못 찾으면 빈 리스트.
  ///
  /// 정답을 보장하는 파서가 아니라 "대부분의 형태를 커버"하는 파서다. 그래서
  /// 호출부는 반드시 폴백 경로를 함께 둔다.
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
}

class YptApiException implements Exception {
  final String message;
  const YptApiException(this.message);

  @override
  String toString() => message;
}

/// 인증 만료(403/108). 재로그인이 필요한 상태.
class YptAuthException extends YptApiException {
  const YptAuthException(super.message);
}

/// 로그인 에러코드 → 사람이 읽을 메시지 (RE 스펙 에러카탈로그)
String errorMessage(String code) {
  switch (code) {
    case '113':
      return 'Sign in failed — incorrect email or password.';
    case '112':
      return 'Authentication failed — check your account.';
    case '104':
      return 'Request rejected.';
    case 'alert_server_error_msg':
      return 'A server error occurred.';
    case 'missing_jwt':
      return 'Sign in failed — the server did not return a session token.';
    default:
      if (code.startsWith('http_')) {
        return 'Request failed (HTTP ${code.substring(5)}).';
      }
      return 'Error (code: $code)';
  }
}
