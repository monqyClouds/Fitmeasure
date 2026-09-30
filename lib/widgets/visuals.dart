import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../domain/dates.dart';
import '../domain/units.dart';

/// A circular progress arc with a rounded, gradient stroke that animates to
/// [value] (0–1). [child] sits in the middle.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    required this.color,
    this.size = 120,
    this.stroke = 10,
    this.child,
  });

  final double value;
  final Color color;
  final double size;
  final double stroke;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: Motion.slow,
      curve: Motion.enter,
      builder: (context, v, child) => CustomPaint(
        painter: _RingPainter(v, color, stroke),
        child: SizedBox.square(
          dimension: size,
          child: Center(child: child),
        ),
      ),
      child: child,
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.stroke);
  final double value;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    canvas.drawArc(
      arc,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = AppColors.surfaceHighest,
    );
    if (value <= 0) return;
    final sweep = math.pi * 2 * value;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [Color.lerp(color, Colors.white, 0.25)!, color, color],
        stops: const [0, 0.6, 1],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    // A soft glow under the arc.
    canvas.drawArc(
      arc,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawArc(arc, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.stroke != stroke;
}

/// Soft coloured light behind a header, so screens aren't flat black.
class GlowBackdrop extends StatelessWidget {
  const GlowBackdrop({
    super.key,
    required this.color,
    required this.child,
    this.secondary,
    this.height = 320,
  });

  final Color color;
  final Color? secondary;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: height,
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: Motion.slow,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.9, -1.1),
                  radius: 1.3,
                  colors: [
                    color.withValues(alpha: 0.22),
                    color.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (secondary != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: height,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(1.2, -0.6),
                    radius: 1.0,
                    colors: [
                      secondary!.withValues(alpha: 0.14),
                      secondary!.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// An icon badge over a big number and a small label.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.tile),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: 0.12), AppColors.surface),
            AppColors.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: t.titleLarge),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Monday to Sunday of the current week. Trained days are filled with the
/// accent, planned days get a dot, today is outlined.
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.trained,
    this.planned = const {},
    this.now,
  });

  /// Dates with a finished workout (time of day ignored).
  final Set<DateTime> trained;

  /// Weekdays (1 = Monday) the plan schedules training on.
  final Set<int> planned;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final today = dateOnly(now ?? DateTime.now());
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final days = trained.map(dateOnly).toSet();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < 7; i++)
          Builder(
            builder: (context) {
              final d = monday.add(Duration(days: i));
              final done = days.contains(d);
              final isToday = d == today;
              final isPlanned = planned.contains(d.weekday);
              return Column(
                children: [
                  Text(
                    weekdayShort[i].substring(0, 1),
                    style: t.labelSmall!.copyWith(
                      color: isToday
                          ? AppColors.textPrimary
                          : AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedContainer(
                    duration: Motion.medium,
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: done ? accent : AppColors.surfaceHigh,
                      border: isToday && !done
                          ? Border.all(color: accent, width: 2)
                          : null,
                      boxShadow: done
                          ? [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.35),
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                    child: done
                        ? Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: onColor(accent),
                          )
                        : Text(
                            '${d.day}',
                            style: t.labelMedium!.copyWith(
                              color: d.isAfter(today)
                                  ? AppColors.textTertiary
                                  : AppColors.textSecondary,
                            ),
                          ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isPlanned && !done
                          ? accent.withValues(alpha: 0.7)
                          : Colors.transparent,
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// Small bar chart of one value per workout, oldest to newest.
class MiniBarChart extends StatelessWidget {
  const MiniBarChart({
    super.key,
    required this.values,
    required this.color,
    this.height = 64,
  });

  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final max = values.fold<double>(0, math.max);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: max <= 0 ? 1 : max * 1.1,
          minY: 0,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          barTouchData: BarTouchData(enabled: false),
          alignment: BarChartAlignment.spaceBetween,
          barGroups: [
            for (final (i, v) in values.indexed)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: v <= 0 ? max * 0.03 + 0.01 : v,
                    width: 10,
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: i == values.length - 1
                          ? [color.withValues(alpha: 0.7), color]
                          : [
                              color.withValues(alpha: 0.18),
                              color.withValues(alpha: 0.45),
                            ],
                    ),
                  ),
                ],
              ),
          ],
        ),
        duration: Motion.slow,
      ),
    );
  }
}

/// GitHub-style grid of the last [weeks] weeks, one square per day, shaded
/// by how much was done that day. Columns are weeks, Monday at the top.
class TrainingHeatmap extends StatelessWidget {
  const TrainingHeatmap({
    super.key,
    required this.values,
    required this.color,
    this.weeks = 12,
    this.now,
  });

  /// Amount per day (e.g. sets), keyed by date with the time ignored.
  final Map<DateTime, double> values;
  final Color color;
  final int weeks;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final today = dateOnly(now ?? DateTime.now());
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));
    final start = thisMonday.subtract(Duration(days: 7 * (weeks - 1)));
    final max = values.values.fold<double>(0, math.max);

    Color shade(double v) {
      if (v <= 0) return AppColors.surfaceHigh;
      final f = max <= 0 ? 1.0 : (v / max).clamp(0.0, 1.0);
      return color.withValues(alpha: 0.3 + 0.7 * f);
    }

    return LayoutBuilder(
      builder: (context, box) {
        const gap = 4.0;
        const labelWidth = 18.0;
        final cell = ((box.maxWidth - labelWidth - gap * (weeks - 1)) / weeks)
            .clamp(8.0, 22.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Column(
                    children: [
                      for (var d = 0; d < 7; d++)
                        SizedBox(
                          height: cell + (d < 6 ? gap : 0),
                          child: d.isEven
                              ? Text(
                                  weekdayShort[d].substring(0, 1),
                                  style: t.labelSmall!.copyWith(
                                    color: AppColors.textTertiary,
                                    fontSize: 9,
                                  ),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
                for (var w = 0; w < weeks; w++) ...[
                  if (w > 0) const SizedBox(width: gap),
                  Column(
                    children: [
                      for (var d = 0; d < 7; d++) ...[
                        if (d > 0) const SizedBox(height: gap),
                        Builder(
                          builder: (context) {
                            final day = start.add(Duration(days: w * 7 + d));
                            final future = day.isAfter(today);
                            return Container(
                              width: cell,
                              height: cell,
                              decoration: BoxDecoration(
                                color: future
                                    ? Colors.transparent
                                    : shade(values[day] ?? 0),
                                borderRadius: BorderRadius.circular(cell / 4),
                                border: day == today
                                    ? Border.all(
                                        color: AppColors.textSecondary,
                                        width: 1.2,
                                      )
                                    : null,
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Less',
                  style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
                ),
                const SizedBox(width: 6),
                for (final f in [0.0, 0.25, 0.6, 1.0]) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: f == 0
                          ? AppColors.surfaceHigh
                          : color.withValues(alpha: 0.3 + 0.7 * f),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 3),
                ],
                const SizedBox(width: 3),
                Text(
                  'More',
                  style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
