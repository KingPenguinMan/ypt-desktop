import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../history_models.dart';
import '../main.dart' show kBrand, kCard;

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
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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
                  // 透明 MouseRegion 只为捕获 hover，触摸设备上靠点选图例。
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(width: 20),
              // 中心或右侧显示当前聚焦项的数值
              Expanded(
                child: hovered == null
                    ? _Legend(
                        slices: data.slices,
                        total: data.totalMs,
                        onHover: (i) => setState(() => _hoverIndex = i),
                      )
                    : _FocusedDetail(slice: hovered, total: data.totalMs),
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
    final radius = math.min(size.width, size.height) / 2 - 6;
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
        // 高亮时加粗并外扩，非高亮时用半透明让被选中的更突出。
        ..strokeWidth = isHot ? radius * 0.42 : radius * 0.34
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
  bool shouldRepaint(_PiePainter old) =>
      old.total != total ||
      old.highlightIndex != highlightIndex ||
      old.slices.length != slices.length;
}

class _Legend extends StatelessWidget {
  final List<PieSlice> slices;
  final int total;
  final ValueChanged<int?> onHover;

  const _Legend({
    required this.slices,
    required this.total,
    required this.onHover,
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
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${(slices[i].value / total * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontFeatures: [FontFeature.tabularFigures()],
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

class _FocusedDetail extends StatelessWidget {
  final PieSlice slice;
  final int total;

  const _FocusedDetail({required this.slice, required this.total});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: slice.color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  slice.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _fmtMs(slice.value),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '占总时长 ${(slice.value / total * 100).toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
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
