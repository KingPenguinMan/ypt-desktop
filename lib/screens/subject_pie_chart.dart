import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../history_models.dart';

/// 扇形图（科目占比）。
///
/// 自绘而不是引第三方图表库，理由：
///  1. 项目定位是非官方客户端，依赖越少越容易长期维护
///  2. 扇形图逻辑简单，一个 CustomPainter 就够，引入库不划算
///  3. 需要和科目卡片的颜色体系严格一致，自绘更好控制
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

class _SubjectPieChartState extends State<SubjectPieChart> {
  int? _hoverIndex;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.isEmpty) {
      return SizedBox(
        height: widget.size,
        child: const Center(
          child: Text('No study data yet',
              style: TextStyle(color: Color(0xFF757575), fontSize: 13)),
        ),
      );
    }

    final hovered =
        _hoverIndex != null && _hoverIndex! < data.slices.length
            ? data.slices[_hoverIndex!]
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: widget.size,
          child: Row(
            children: [
              SizedBox(
                width: widget.size,
                height: widget.size,
                child: CustomPaint(
                  painter: _PiePainter(
                    slices: data.slices,
                    total: data.totalMs,
                    highlightIndex: _hoverIndex,
                  ),
                  // 圆环中心显示当前聚焦项的数值。
                  //
                  // 详情原先放在右侧、和图例争用同一个 Expanded 槽位——
                  // 鼠标移上图例行后图例被替换掉，被 hover 的组件随即从树上
                  // 消失，触发 onExit 复位，图例又出现，onEnter 再触发……
                  // 结果是图例疯狂闪烁。改到中心就消除了这个竞争：
                  // 图例始终在，hover 目标不会消失。
                  child: Center(
                    child: _FocusedDetail(
                      slice: hovered,
                      total: data.totalMs,
                      // 内孔直径约为 size*0.59（见 _PiePainter 的几何推算），
                      // 取 0.5 留出余量，避免文字压到环上。
                      innerSize: widget.size * 0.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 20),
              // 图例常驻，不随 hover 切换。
              Expanded(
                child: _Legend(
                  slices: data.slices,
                  total: data.totalMs,
                  onHover: (i) => setState(() => _hoverIndex = i),
                  activeIndex: _hoverIndex,
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

  _PiePainter({
    required this.slices,
    required this.total,
    this.highlightIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final center = size.center(Offset.zero);

    // 几何要点：drawArc 的描边以路径为中心向两侧各扩一半。
    // 原先写 radius = halfSize - 6 再配 strokeWidth = radius * 0.34，
    // 外缘会到 radius + strokeWidth/2 = 92.4，而画布半宽只有 85 ——
    // 圆环被画布裁掉，看起来像缺了边。
    // 现在反过来：先定最大可用半径，由它推出描边厚度和绘制半径，
    // 并用最粗的那档（高亮态）来算，保证高亮时也不越界。
    final maxR = math.min(size.width, size.height) / 2;
    final baseThick = maxR * 0.32;
    final hotThick = baseThick * 1.25;
    final radius = maxR - hotThick / 2 - 1; // 留 1px 边
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 起点在12 点方向，顺时针。
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
        ..strokeWidth = isHot ? hotThick : baseThick
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

class _Legend extends StatelessWidget {
  final List<PieSlice> slices;
  final int total;
  final ValueChanged<int?> onHover;

  /// 当前聚焦项，用于把对应行加重显示。图例本身始终完整可见。
  final int? activeIndex;

  const _Legend({
    required this.slices,
    required this.total,
    required this.onHover,
    this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < slices.length; i++)
          MouseRegion(
            onEnter: (_) => onHover(i),
            onExit: (_) => onHover(null),
            child: GestureDetector(
              onTap: () => onHover(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
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
                    const SizedBox(width: 6),
                    Text(
                      '${(slices[i].value / total * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 12,
                        // 选中行用亮色，其余用灰，避免只靠加粗区分。
                        color: activeIndex == i
                            ? const Color(0xFFE8E8E8)
                            : const Color(0xFF9E9E9E),
                        fontWeight: activeIndex == i
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 圆环中心的内容：未聚焦时显示总时长，聚焦时显示该项的时长与占比。
///
/// 放在圆环中心而不是侧栏，是为了不和图例争用同一个布局槽位——
/// 那会导致图例在 hover 时被替换、进而疯狂闪烁。
class _FocusedDetail extends StatelessWidget {
  final PieSlice? slice;
  final int total;

  /// 圆环内孔直径，用来约束文字宽度，避免文字压到环上。
  final double innerSize;

  const _FocusedDetail({
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
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
