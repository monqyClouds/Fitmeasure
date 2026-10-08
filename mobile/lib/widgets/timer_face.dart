import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../domain/units.dart';

/// A countdown: a ring that empties as time runs out, the time left in the
/// middle, and what's happening ("WORK", "REST", "WATER BREAK") above it.
/// The owner rebuilds it as time passes.
class TimerFace extends StatelessWidget {
  const TimerFace({
    super.key,
    required this.label,
    required this.remaining,
    required this.total,
    required this.color,
    this.size = 260,
    this.paused = false,
    this.untimed,
  });

  final String label;
  final Duration remaining;
  final Duration total;
  final Color color;
  final double size;
  final bool paused;

  /// Shown instead of a time for a step without one ("12 reps").
  final String? untimed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final secs = (remaining.inMilliseconds / 1000).ceil();
    final fraction = total.inMilliseconds == 0
        ? 1.0
        : remaining.inMilliseconds / total.inMilliseconds;
    // The last three seconds pulse.
    final urgent = untimed == null && !paused && secs <= 3 && secs > 0;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: untimed != null ? 1 : fraction.clamp(0.0, 1.0),
          color: paused ? color.withValues(alpha: 0.45) : color,
          stroke: size * 0.055,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(Radii.chip),
                ),
                child: Text(
                  paused ? 'PAUSED' : label,
                  style: t.labelMedium!.copyWith(
                    color: color,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SizedBox(height: size * 0.03),
              AnimatedScale(
                scale: urgent ? 1.08 : 1,
                duration: const Duration(milliseconds: 180),
                child: Text(
                  untimed ?? formatDuration(secs),
                  textAlign: TextAlign.center,
                  style: (untimed == null ? t.displayLarge : t.headlineMedium)!
                      .copyWith(
                        fontSize: untimed == null ? size * 0.25 : size * 0.2,
                        fontWeight: FontWeight.w800,
                        color: urgent ? color : AppColors.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        height: 1.05,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.color,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect =
        Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.14),
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: math.pi * 1.5,
          colors: [color.withValues(alpha: 0.6), color],
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.stroke != stroke;
}
