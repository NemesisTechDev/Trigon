import 'package:flutter/material.dart';

/// Solid dustbin (open lid, three slots) used for every delete / remove
/// action. Drawn with a CustomPainter so it scales crisply and takes any
/// color; with no [color] / [size] it inherits from the surrounding
/// [IconTheme], so it works inside IconButton (incl. disabled colour) exactly
/// like a Material [Icon].
///
/// [sweep] adds three short "sweep" lines on the right (bin on the left) and shrinks the bin
/// (the "remove all" variant, replacing Icons.delete_sweep).
class DustbinIcon extends StatelessWidget {
  final double? size;
  final Color? color;
  final bool sweep;
  const DustbinIcon({super.key, this.size, this.color, this.sweep = false});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24.0;
    var c = color ?? theme.color ?? Colors.white;
    final o = theme.opacity;
    if (o != null && o != 1.0) c = c.withValues(alpha: c.a * o);
    return SizedBox(
      width: s,
      height: s,
      child: CustomPaint(painter: _DustbinPainter(c, sweep)),
    );
  }
}

class _DustbinPainter extends CustomPainter {
  final Color color;
  final bool sweep;
  _DustbinPainter(this.color, this.sweep);

  Path _poly(List<List<double>> pts) {
    final p = Path()..moveTo(pts[0][0], pts[0][1]);
    for (var i = 1; i < pts.length; i++) {
      p.lineTo(pts[i][0], pts[i][1]);
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.scale(size.width / 512.0);

    // The artwork spans x 82..430, y 13..500 of a 512 box. Scale it down a
    // little so its visual weight matches Material icons, centred.
    final k = sweep ? 0.74 : 0.84;
    final cx = sweep ? 171.0 : 256.0; // bin centre x (sweep: bin on the left)
    final cy = sweep ? 262.0 : 256.0;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(k);
    canvas.translate(-256, -256);

    // Body with three slots cut out.
    final body = Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(
          _poly([
            [131, 184],
            [423, 184],
            [392, 499],
            [162, 499],
          ]),
          Offset.zero)
      ..addPath(
          _poly([
            [197, 215],
            [222, 215],
            [232, 442],
            [207, 442],
          ]),
          Offset.zero)
      ..addPath(
          _poly([
            [265, 215],
            [291, 215],
            [291, 442],
            [265, 442],
          ]),
          Offset.zero)
      ..addPath(
          _poly([
            [330, 215],
            [355, 215],
            [347, 442],
            [322, 442],
          ]),
          Offset.zero);
    canvas.drawPath(body, paint);

    // Lid bar.
    canvas.drawPath(
      _poly([
        [82, 140],
        [413, 20],
        [430, 53],
        [97, 173],
      ]),
      paint,
    );

    // Lid handle (hollow).
    final handle = Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(
          _poly([
            [170, 60],
            [297, 13],
            [314, 58],
            [190, 104],
          ]),
          Offset.zero)
      ..addPath(
          _poly([
            [200, 77],
            [287, 44],
            [294, 62],
            [208, 94],
          ]),
          Offset.zero);
    canvas.drawPath(handle, paint);
    canvas.restore();

    if (sweep) {
      final line = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = 30;
      // Lines sit on the RIGHT, right up against the bin's right edge so the
      // two read as one glyph (bin body ends at x~291 at this scale). Exact
      // horizontal mirror of the previous left-side lines (x -> 512 - x).
      canvas.drawLine(const Offset(450, 244), const Offset(320, 244), line);
      canvas.drawLine(const Offset(450, 314), const Offset(334, 314), line);
      canvas.drawLine(const Offset(450, 384), const Offset(348, 384), line);
    }
  }

  @override
  bool shouldRepaint(_DustbinPainter old) =>
      old.color != color || old.sweep != sweep;
}
