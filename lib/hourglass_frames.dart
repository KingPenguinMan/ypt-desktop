import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

/// Small vector-rendered frames, encoded once at startup. No per-tick raster work.
Future<List<String>> buildHourglassFrames() async {
  final result = <String>[];
  for (var frame = 0; frame < 20; frame++) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.translate(32, 32);
    final progress = math.min(frame / 15, 1.0);
    if (frame > 15) canvas.rotate(math.pi * (frame - 15) / 5);
    final framePaint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..strokeWidth = 4
      ..strokeCap = ui.StrokeCap.round
      ..style = ui.PaintingStyle.stroke;
    canvas.drawLine(
      const ui.Offset(-17, -24),
      const ui.Offset(17, -24),
      framePaint,
    );
    canvas.drawLine(
      const ui.Offset(-17, 24),
      const ui.Offset(17, 24),
      framePaint,
    );
    final glass = ui.Path()
      ..moveTo(-14, -21)
      ..lineTo(14, -21)
      ..lineTo(13, -13)
      ..lineTo(3, 0)
      ..lineTo(13, 13)
      ..lineTo(14, 21)
      ..lineTo(-14, 21)
      ..lineTo(-13, 13)
      ..lineTo(-3, 0)
      ..lineTo(-13, -13)
      ..close();
    canvas.drawPath(glass, framePaint);
    canvas.save();
    canvas.clipPath(glass);
    final sand = ui.Paint()..color = const ui.Color(0xFFFFA45C);
    final top = -19 + 18 * progress;
    canvas.drawRect(ui.Rect.fromLTRB(-12, top, 12, -2), sand);
    final bottom = 20 - 18 * progress;
    canvas.drawPath(
      ui.Path()
        ..moveTo(-14, 21)
        ..lineTo(0, bottom)
        ..lineTo(14, 21)
        ..close(),
      sand,
    );
    if (frame > 0 && frame < 15) {
      canvas.drawRect(ui.Rect.fromLTRB(-1, -2, 1, bottom), sand);
    }
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 64);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('Could not render tray frame');
    result.add(base64Encode(png.buffer.asUint8List()));
    image.dispose();
    picture.dispose();
  }
  return result;
}
