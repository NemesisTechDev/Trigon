import 'package:flutter/material.dart';

/// Outlined filmstrip-with-play icon (used for the Trailers button), traced
/// from a 512x512 design. Takes colour / size from arguments or, when
/// omitted, from the surrounding [IconTheme] like a Material [Icon].
class FilmstripIcon extends StatelessWidget {
  final double? size;
  final Color? color;
  const FilmstripIcon({super.key, this.size, this.color});

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
      child: CustomPaint(painter: _FilmstripPainter(c)),
    );
  }
}

class _FilmstripPainter extends CustomPainter {
  final Color color;
  _FilmstripPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 512.0);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 30;

    // Sprocket rails.
    for (final x in const [15.0, 105.0, 405.0, 497.0]) {
      canvas.drawLine(Offset(x, 28), Offset(x, 482), p);
    }
    // Sprocket rungs.
    for (final y in const [75.0, 165.0, 255.0, 345.0, 435.0]) {
      canvas.drawLine(Offset(15, y), Offset(105, y), p);
      canvas.drawLine(Offset(405, y), Offset(497, y), p);
    }
    // Frame top and bottom edges.
    canvas.drawPath(
      Path()
        ..moveTo(105, 92)
        ..quadraticBezierTo(112, 105, 135, 105)
        ..lineTo(375, 105)
        ..quadraticBezierTo(398, 105, 405, 92),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(105, 418)
        ..quadraticBezierTo(112, 405, 135, 405)
        ..lineTo(375, 405)
        ..quadraticBezierTo(398, 405, 405, 418),
      p,
    );
    // Play triangle.
    canvas.drawPath(
      Path()
        ..moveTo(226, 197)
        ..lineTo(315, 255)
        ..lineTo(226, 313)
        ..close(),
      p,
    );
  }

  @override
  bool shouldRepaint(_FilmstripPainter old) => old.color != color;
}
