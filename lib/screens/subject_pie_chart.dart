import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../history_models.dart';

/// 扇形图（科目占比）。
///
/// 自绘而不是引第三方图表库，理由：
///  1. 项目定位是非官方客户端，依赖越少越容易长期维护
///  2. 扇形图逻辑简单，一个 CustomPainter 就够，引入库不划算
///  3. 需要和科目卡片的颜色体系严格一致，自绘更好控制
///
/// 交互说明：
///  · 悬浮在**圆环扇区上**或**图例某一行上**，都会聚焦该科目
///  · 聚焦时该扇区高亮加粗、图例对应行加粗、圆环中心显示它的时长
///  · 未聚焦时圆环中心显示当天总计
///
/// 图例始终显示「科目 / 时长 / 占比」三项，**不依赖悬浮**就能读到完整信息
/// —— 之前只显示科目名和百分比，用户反馈"看不到各个部分的详细信息"。
class SubjectPieChart extends StatefulWidget {
  final SubjectBreakdown data;
  final double size;
  final bool showLegend;

  const SubjectPieChart({
    super.key,
    required this.data,
    this.size = 180,
    this.showLegend = true,
  });

  @override
  State<SubjectPieChart> createState() => _SubjectPieChartState();
}

/// 圆环几何。
///
/// 绘制和命中测试**必须共用同一份计算**，否则会出现"看着指着扇区却选不中"
/// 的偏差——两处各算一次半径是最容易埋进去的坑。
class _RingGeometry {
  /// 圆心坐标（正方形边长的中点）。
  final double center;

  /// 描边中心线半径。
  final double radius;

  /// 常规描边宽度。
  final double baseThickness;

  /// 高亮时的描边宽度（更粗）。
  final double hotThickness;

  const _RingGeometry({
    required this.center,
    required this.radius,
    required this.baseThickness,
    required this.hotThickness,
  });

  /// 由边长推算几何。
  ///
  /// 关键：描边以路径为中心向两侧各扩一半，所以半径必须按**最粗**的那档
  /// 反推，否则高亮时会超出画布被裁掉（曾经就是这个原因导致圆环缺边）。
  factory _RingGeometry.of(double size) {
    final maxR = size / 2;
    final base = maxR * 0.32;
    final hot = base * 1.25;
    return _RingGeometry(
      center: size / 2,
      radius: maxR - hot / 2 - 1, // 留 1px 边
      baseThickness: base,
      hotThickness: hot,
    );
  }

  double get innerR => radius - hotThickness / 2;
  double get outerR => radius + hotThickness / 2;
}

class _SubjectPieChartState extends State<SubjectPieChart> {
  int? _hoverIndex;

  /// 点击固定住的选中项。
  ///
  /// 只做悬浮的话，鼠标一移开高亮就没了——用户看不到"我选中了哪个"。
  /// 悬浮优先级高于固定：鼠标在某项上时跟随鼠标，移开后回到固定项。
  int? _pinnedIndex;

  /// 当前生效的聚焦项。
  int? get _activeIndex => _hoverIndex ?? _pinnedIndex;

  /// 命中测试：返回鼠标所在扇区的下标，不在环上时返回 null。
  ///
  /// 用与 [_PiePainter] 完全相同的几何和角度累加方式，保证"指哪选哪"。
  int? _hitTest(Offset local) {
    final slices = widget.data.slices;
    final total = widget.data.totalMs;
    if (total <= 0 || slices.isEmpty) return null;

    final g = _RingGeometry.of(widget.size);
    final v = local - Offset(g.center, g.center);
    final r = v.distance;
    // 给边缘一点容差，避免贴着边时点不中。
    if (r < g.innerR - 2 || r > g.outerR + 2) return null;

    // 从 12 点方向开始、顺时针累加，与绘制顺序一致。
    var ang = math.atan2(v.dy, v.dx) + math.pi / 2;
    if (ang < 0) ang += 2 * math.pi;

    var acc = 0.0;
    for (var i = 0; i < slices.length; i++) {
      acc += (slices[i].value / total) * 2 * math.pi;
      if (ang < acc) return i;
    }
    return slices.length - 1;
  }

  void _setHover(int? i) {
    if (_hoverIndex == i) return;
    setState(() => _hoverIndex = i);
  }

  /// 点击切换固定选中；点同一项两次取消。
  void _togglePin(int? i) {
    setState(() => _pinnedIndex = (_pinnedIndex == i) ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.isEmpty) {
      return SizedBox(
        height: widget.size,
        child: const Center(
          child: Text(
            'No study data yet',
            style: TextStyle(color: Color(0xFF757575), fontSize: 13),
          ),
        ),
      );
    }

    final active = _activeIndex;
    final focused = active != null && active >= 0 && active < data.slices.length
        ? data.slices[active]
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: widget.size,
          child: Row(
            children: [
              MouseRegion(
                // 悬浮在扇区上直接聚焦——比"只能去图例上找"直观得多。
                onHover: (e) => _setHover(_hitTest(e.localPosition)),
                onExit: (_) => _setHover(null),
                child: GestureDetector(
                  // 点圆环内部（不是扇区）时取消固定。
                  onTapUp: (d) => _togglePin(_hitTest(d.localPosition)),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: widget.size,
                    height: widget.size,
                    child: CustomPaint(
                      painter: _PiePainter(
                        slices: data.slices,
                        total: data.totalMs,
                        highlightIndex: active,
                      ),
                      // 圆环中心显示当前聚焦项的数值。
                      //
                      // 详情原先放在右侧、和图例争用同一个 Expanded 槽位——
                      // 鼠标移上图例行后图例被替换掉，被 hover 的组件随即从树上
                      // 消失，触发 onExit 复位，图例又出现，onEnter 再触发……
                      // 结果是图例疯狂闪烁。改到中心就消除了这个竞争：
                      // 图例始终在，hover 目标不会消失。
                      child: Center(
                        child: _CenterDetail(
                          slice: focused,
                          total: data.totalMs,
                          innerSize:
                              _RingGeometry.of(widget.size).innerR * 2 * 0.92,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              if (widget.showLegend)
                Expanded(
                  child: _Legend(
                    slices: data.slices,
                    total: data.totalMs,
                    onHover: _setHover,
                    onTap: _togglePin,
                    activeIndex: active,
                    pinnedIndex: _pinnedIndex,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PiePainter extends CustomPainter {
  final List<PieSlice> slices;
  final int total;
  final int? highlightIndex;

  _PiePainter({required this.slices, required this.total, this.highlightIndex});

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final g = _RingGeometry.of(size.width);
    final rect = Rect.fromCircle(
      center: Offset(g.center, g.center),
      radius: g.radius,
    );

    // 起点在 12 点方向，顺时针。
    var startAngle = -math.pi / 2;
    const gap = 0.02; // 扇区间隙，让相邻色块有分界

    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final sweep = (slice.value / total) * 2 * math.pi;
      // 单个扇区若过小（<0.5°）就不画，否则会退化成一条线，反而难看。
      if (sweep < 0.009) {
        startAngle += sweep;
        continue;
      }
      final isHot = highlightIndex == i;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isHot ? g.hotThickness : g.baseThickness
        ..strokeCap = StrokeCap.butt
        ..color = isHot
            ? slice.color
            : (highlightIndex == null
                  ? slice.color
                  : slice.color.withValues(alpha: 0.32));

      final pad = slices.length > 1 ? gap : 0.0;
      canvas.drawArc(
        rect,
        startAngle + pad / 2,
        (sweep - pad).clamp(0.0, 2 * math.pi),
        false,
        paint,
      );
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) {
    if (old.total != total || old.highlightIndex != highlightIndex) return true;
    if (old.slices.length != slices.length) return true;
    // 只比长度不够：科目时长变化但段数不变时（例如两个科目互换大小），
    // 画布不会重绘，界面上就是过期数据。逐项比较值与颜色。
    for (var i = 0; i < slices.length; i++) {
      if (old.slices[i].value != slices[i].value) return true;
      if (old.slices[i].color != slices[i].color) return true;
      if (old.slices[i].label != slices[i].label) return true;
    }
    return false;
  }
}

/// 图例：每行「色块 / 科目名 / 时长 / 占比」。
///
/// 时长必须常显——只给百分比的话，用户看到"数学 85%"却不知道是多少时间，
/// 而这恰恰是想知道的（用户反馈"看不到各个部分的详细信息"）。
class _Legend extends StatelessWidget {
  final List<PieSlice> slices;
  final int total;
  final ValueChanged<int?> onHover;
  final ValueChanged<int?> onTap;

  /// 当前聚焦项（悬浮或固定），用于把对应行加重显示。
  final int? activeIndex;

  /// 被点击固定住的项，用左侧小竖条标出来。
  /// 否则用户看不出"我钉住了哪个"和"只是鼠标扫过"的区别。
  final int? pinnedIndex;

  const _Legend({
    required this.slices,
    required this.total,
    required this.onHover,
    required this.onTap,
    this.activeIndex,
    this.pinnedIndex,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 离开整块图例才清除悬浮聚焦，避免在行与行之间移动时反复闪烁。
      onExit: (_) => onHover(null),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < slices.length; i++)
            MouseRegion(
              onEnter: (_) => onHover(i),
              child: GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        // 固定标记：占位固定宽度，避免有无标记时整行左右跳动。
                        SizedBox(
                          width: 3,
                          height: 14,
                          child: pinnedIndex == i
                              ? DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: slices[i].color,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: slices[i].color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            slices[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: activeIndex == i
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _fmtMs(slices[i].value),
                          style: TextStyle(
                            fontSize: 12,
                            color: activeIndex == i
                                ? const Color(0xFFE8E8E8)
                                : const Color(0xFF9E9E9E),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 10),
                        // 固定宽度让百分比右对齐成一列，便于纵向比较。
                        SizedBox(
                          width: 34,
                          child: Text(
                            '${(slices[i].value / total * 100).toStringAsFixed(0)}%',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: activeIndex == i
                                  ? const Color(0xFFE8E8E8)
                                  : const Color(0xFF9E9E9E),
                              fontWeight: activeIndex == i
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 圆环中心的内容：未聚焦时显示总时长，聚焦时显示该项的时长与占比。
class _CenterDetail extends StatelessWidget {
  final PieSlice? slice;
  final int total;

  /// 圆环内孔直径，用来约束文字宽度，避免文字压到环上。
  final double innerSize;

  const _CenterDetail({
    required this.slice,
    required this.total,
    required this.innerSize,
  });

  @override
  Widget build(BuildContext context) {
    final s = slice;
    return SizedBox(
      width: innerSize,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s == null ? '今日总计' : s.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E)),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _fmtMs(s?.value ?? total),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (s != null && total > 0)
            Text(
              '${(s.value / total * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E)),
            ),
        ],
      ),
    );
  }
}

String _fmtMs(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) {
    // 不足一分钟时不能直接取 inMinutes —— 那会显示成 "0m"，
    // 读起来像"没有数据"，而实际上是有几十秒的。
    if (d.inMinutes == 0) return d.inSeconds > 0 ? '<1m' : '0m';
    return '${m}m';
  }
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
