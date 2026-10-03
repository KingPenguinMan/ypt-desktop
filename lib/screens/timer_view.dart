import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart' show kBrand, kCard, kCard2;
import '../models.dart';
import 'gap_prompt_dialog.dart';

String fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

String fmtMs(int ms) => fmt(Duration(milliseconds: ms));

class TimerView extends StatelessWidget {
  const TimerView({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final user = st.user!;
    final baseMs = st.todayStudyMs; // 과목별 합산 (타이머+수동추가)
    final active = st.activeSubject;
    final ringColor = active?.color ?? kBrand;

    return Column(
      children: [
        const SizedBox(height: 24),
        // 원형 타이머.
        // CustomPaint 의 painter 가 매초 바뀌므로, tick 구독을 가진
        // _RingTimer 안에서만 다시 그린다. 이 Column 은 더 이상 매초
        // 리빌드되지 않는다(IndexedStack 에 4 개 탭이 모두 살아 있으므로
        // 매초 전체 리빌드는 눈에 띄는 프레임 드롭을 만든다).
        SizedBox(
          width: 250,
          height: 250,
          child: _RingTimer(
            color: ringColor,
            activeTitle: active?.title,
            // 클로저가 매초 호출되어 현재 elapsed 를 반영한다.
            format: (elapsed) => fmtMs(baseMs + elapsed.inMilliseconds),
          ),
        ),
        const SizedBox(height: 16),
        if (st.timerUncertain)
          TextButton.icon(
            onPressed: st.timerLoading ? null : st.reconcileTimer,
            icon: const Icon(Icons.sync),
            label: const Text('同步计时状态'),
          ),
        if (st.studying)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: ringColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            onPressed: st.timerLoading
                ? null
                : () => context.read<AppState>().stopTimer(),
            icon: st.timerLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.stop_rounded),
            label: const Text(
              'STOP',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
          )
        else
          const SizedBox(height: 44),
        if (st.timerErrorText != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              st.timerErrorText!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 20),
        // 과목 카드 리스트 — 비어 있으면 새로고침 버튼
        Expanded(
          child: user.subjects.isEmpty
              ? Center(
                  child: st.profileLoading
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'No subjects loaded',
                              style: TextStyle(
                                color: Color(0xFF757575),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  context.read<AppState>().reloadProfile(),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Refresh'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: kBrand,
                                side: BorderSide(
                                  color: kBrand.withValues(alpha: 0.5),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: user.subjects.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) =>
                      _SubjectCard(subject: user.subjects[i]),
                ),
        ),
      ],
    );
  }
}

/// 원형 타이머 전체(링 + 숫자 + 과목명).
///
/// [AppState] 의 tick 채널만 구독하므로, 매초 리빌드되는 범위가 이
/// 250x250 박스로 제한된다. 바깥 TimerView 는科目 목록/ 버튼 상태가 실제로
/// 바뀔 때만 리빌드된다.
class _RingTimer extends StatefulWidget {
  final Color color;
  final String? activeTitle;
  final String Function(Duration elapsed) format;

  const _RingTimer({
    required this.color,
    required this.activeTitle,
    required this.format,
  });

  @override
  State<_RingTimer> createState() => _RingTimerState();
}

class _RingTimerState extends State<_RingTimer> {
  VoidCallback? _cancel;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _cancel = app.addTickListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // listen: false — 이미 tick 으로 받고 있으므로 전역 구독은 필요 없다.
    final app = context.read<AppState>();
    final studying = app.studying;
    final elapsed = app.elapsed;
    // 진행 중이면 1분 주기로 채워지는 링, 아니면 비움
    final progress = studying ? (elapsed.inSeconds % 60) / 60.0 : 0.0;
    final title = widget.activeTitle;

    return CustomPaint(
      painter: _RingPainter(progress: progress, color: widget.color),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "TODAY",
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.format(studying ? elapsed : Duration.zero),
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w300,
                letterSpacing: 1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            if (title != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  title,
                  style: TextStyle(
                    color: widget.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              )
            else
              const Text(
                "Tap a subject to start",
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  final Subject subject;
  const _SubjectCard({required this.subject});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    final s = subject;
    final active = st.activeSubject?.id == s.id;
    final disabled = st.timerLoading;
    final today = st.subjectStudyMs(s);

    void toggle() {
      final app = context.read<AppState>();
      if (active) {
        app.stopTimer();
        return;
      }
      // 开始计时前，若上一段空档够长就先问"这段时间在做什么"。
      //
      // 必须在这里问，不能像之前那样在停止时问：空档从"停止那一刻"开始
      // 累积，停止后立刻弹窗时它还是 0 秒，永远达不到最短阈值，
      // 弹窗因此从不出现（这是上一版的逻辑自相矛盾）。
      // 等到用户再次开始时，空档已经真实累积，阈值判断才有意义。
      if (GapPromptDialog.shouldAsk(app.pendingGap)) {
        GapPromptDialog.maybeShow(context, app.pendingGap).then((_) {
          if (context.mounted && app.loggedIn) app.startTimer(s);
        });
      } else {
        app.startTimer(s);
      }
    }

    return Opacity(
      opacity: disabled && !active ? 0.55 : 1,
      child: Material(
        color: active ? kCard2 : kCard,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled ? null : toggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: active
                  ? Border.all(
                      color: s.color.withValues(alpha: 0.6),
                      width: 1.4,
                    )
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: s.color.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    active ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: s.color,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    s.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: active ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
                // 활성화된 과목 하나만 초 단위로 갱신한다. 과목 카드 전체를
                // 매초 리빌드하면 리스트 길이에 비례해 비용이 늘어난다.
                if (active)
                  _ActiveSubjectTime(baseMs: today, color: s.color)
                else
                  Text(
                    fmtMs(today),
                    style: const TextStyle(
                      color: Colors.grey,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 计时中科目的时长显示。走 tick 通道，秒级刷新但不重建整张卡片。
class _ActiveSubjectTime extends StatefulWidget {
  final int baseMs;
  final Color color;
  const _ActiveSubjectTime({required this.baseMs, required this.color});

  @override
  State<_ActiveSubjectTime> createState() => _ActiveSubjectTimeState();
}

class _ActiveSubjectTimeState extends State<_ActiveSubjectTime> {
  VoidCallback? _cancel;

  @override
  void initState() {
    super.initState();
    _cancel = context.read<AppState>().addTickListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = context.read<AppState>().elapsed;
    return Text(
      fmtMs(widget.baseMs + elapsed.inMilliseconds),
      style: TextStyle(
        color: widget.color,
        fontWeight: FontWeight.bold,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 10;
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawCircle(center, radius, track);

    if (progress > 0) {
      final arc = Paint()
        ..color =
            color // 단색 (그라데이션 제거)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        arc,
      );
    } else {
      final dot = Paint()..color = color.withValues(alpha: 0.4);
      canvas.drawCircle(Offset(center.dx, center.dy - radius), 5, dot);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
