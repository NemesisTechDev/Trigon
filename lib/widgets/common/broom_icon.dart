import 'package:flutter/material.dart';

/// Outlined broom/brush icon used for "Clear Cache". Drawn with a
/// CustomPainter (no asset or package needed), traced from a 512x512 design
/// so it scales crisply at any size and takes any [color].
class BroomIcon extends StatelessWidget {
  final double size;
  final Color color;
  const BroomIcon({super.key, this.size = 24, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BroomPainter(color)),
    );
  }
}

class _BroomPainter extends CustomPainter {
  final Color color;
  _BroomPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 512.0;
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      // Matches the line weight of the source artwork (24 of 512).
      ..strokeWidth = 24;

    // Handle.
    canvas.drawPath(
      Path()
        ..moveTo(238, 195)
        ..lineTo(238, 112)
        ..arcToPoint(const Offset(276, 112),
            radius: const Radius.circular(19), clockwise: true)
        ..lineTo(276, 195),
      paint,
    );

    // Brush head (left half + lower bar).
    canvas.drawPath(
      Path()
        ..moveTo(238, 195)
        ..lineTo(180, 195)
        ..cubicTo(150, 195, 135, 215, 135, 245)
        ..lineTo(135, 253)
        ..lineTo(340, 253),
      paint,
    );

    // Brush head right side down to the base.
    canvas.drawPath(
      Path()
        ..moveTo(276, 195)
        ..lineTo(340, 195)
        ..cubicTo(370, 195, 382, 215, 384, 245)
        ..lineTo(398, 415)
        ..lineTo(115, 415)
        ..lineTo(127, 297),
      paint,
    );

    // Bristles.
    canvas.drawLine(const Offset(173, 357), const Offset(168, 410), paint);
    canvas.drawLine(const Offset(297, 318), const Offset(310, 410), paint);
    canvas.drawLine(const Offset(360, 378), const Offset(365, 410), paint);
  }

  @override
  bool shouldRepaint(_BroomPainter old) => old.color != color;
}
