import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../data/db/database.dart';
import '../domain/dates.dart';
import '../domain/units.dart';

double _x(DateTime d) => d.millisecondsSinceEpoch / Duration.millisecondsPerDay;

DateTime _date(double x) => DateTime.fromMillisecondsSinceEpoch(
  (x * Duration.millisecondsPerDay).round(),
);

/// A line of values over time with a soft gradient fill. The background is
/// banded by [cycles], so trends read against bulk, cut and so on. With
/// [sparkline] it's a bare, compact line for lists and cards.
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.color,
    this.cycles = const [],
    this.unit = '',
    this.height = 200,
    this.sparkline = false,
    this.format,
  });

  final List<(DateTime, double)> points;
  final Color color;
  final List<Cycle> cycles;
  final String unit;
  final double height;
  final bool sparkline;

  /// Formats values for axis labels and tooltips; defaults to numbers.
  final String Function(double)? format;

  String _fmt(double v) => format?.call(v) ?? formatNumber(v);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: sparkline
              ? Container(height: 2, color: AppColors.surfaceHighest)
              : Text(
                  'No entries yet',
                  style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
                ),
        ),
      );
    }

    final spots = [for (final (d, v) in points) FlSpot(_x(d), v)];
    var minX = spots.first.x;
    var maxX = spots.last.x;
    if (maxX - minX < 1) {
      minX -= 3;
      maxX += 3;
    }
    final values = [for (final s in spots) s.y];
    var minY = values.reduce(math.min);
    var maxY = values.reduce(math.max);
    final span = maxY - minY;
    final pad = span == 0 ? math.max(1.0, maxY.abs() * 0.05) : span * 0.15;
    minY -= pad;
    maxY += pad;

    final bands = sparkline
        ? const <VerticalRangeAnnotation>[]
        : [
            for (final c in cycles)
              if (_x(c.startDate) < maxX &&
                  _x(c.endDate ?? dateOnly(DateTime.now())) + 1 > minX)
                VerticalRangeAnnotation(
                  x1: math.max(_x(c.startDate), minX),
                  x2: math.min(
                    _x(c.endDate ?? dateOnly(DateTime.now())) + 1,
                    maxX,
                  ),
                  color: c.type.color.withValues(alpha: 0.09),
                ),
          ];

    final line = LineChartBarData(
      spots: spots,
      isCurved: spots.length > 2,
      curveSmoothness: 0.22,
      preventCurveOverShooting: true,
      color: color,
      barWidth: sparkline ? 2.5 : 3,
      isStrokeCapRound: true,
      dotData: FlDotData(
        show: !sparkline && spots.length <= 40,
        getDotPainter: (spot, _, _, i) => FlDotCirclePainter(
          radius: i == spots.length - 1 ? 5 : 3,
          color: i == spots.length - 1 ? color : AppColors.surface,
          strokeColor: color,
          strokeWidth: 2,
        ),
      ),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: sparkline ? 0.22 : 0.3),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    );

    final labelStyle = t.labelSmall!.copyWith(
      color: AppColors.textTertiary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    );

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          lineBarsData: [line],
          rangeAnnotations: RangeAnnotations(verticalRangeAnnotations: bands),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: !sparkline,
            drawVerticalLine: false,
            horizontalInterval: (maxY - minY) / 4,
            getDrawingHorizontalLine: (_) => const FlLine(
              color: AppColors.outline,
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ),
          titlesData: sparkline
              ? const FlTitlesData(show: false)
              : FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      interval: (maxY - minY) / 4,
                      getTitlesWidget: (v, meta) =>
                          v == meta.min || v == meta.max
                          ? const SizedBox.shrink()
                          : SideTitleWidget(
                              meta: meta,
                              child: Text(_fmt(v), style: labelStyle),
                            ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 26,
                      interval: math.max(1, (maxX - minX) / 3),
                      getTitlesWidget: (v, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(
                          formatShortDate(_date(v)),
                          style: labelStyle,
                        ),
                      ),
                    ),
                  ),
                ),
          lineTouchData: sparkline
              ? const LineTouchData(enabled: false)
              : LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => AppColors.surfaceHighest,
                    tooltipBorderRadius: BorderRadius.circular(12),
                    getTooltipItems: (touched) => [
                      for (final s in touched)
                        LineTooltipItem(
                          '${_fmt(s.y)}${unit.isEmpty ? '' : ' $unit'}\n',
                          t.titleSmall!.copyWith(color: color),
                          children: [
                            TextSpan(
                              text: formatDate(_date(s.x)),
                              style: t.bodySmall!.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  getTouchedSpotIndicator: (bar, indexes) => [
                    for (final _ in indexes)
                      TouchedSpotIndicatorData(
                        FlLine(
                          color: color.withValues(alpha: 0.4),
                          strokeWidth: 1.5,
                          dashArray: const [3, 3],
                        ),
                        FlDotData(
                          getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                            radius: 6,
                            color: color,
                            strokeColor: AppColors.surface,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        duration: Motion.slow,
      ),
    );
  }
}

/// Coloured keys for the cycles shading a chart.
class CycleLegend extends StatelessWidget {
  const CycleLegend({super.key, required this.cycles, required this.from});
  final List<Cycle> cycles;

  /// Only cycles running on or after this date are listed.
  final DateTime from;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final shown = [
      for (final c in cycles.reversed)
        if (c.endDate == null || !c.endDate!.isBefore(dateOnly(from))) c,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final c in shown)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: c.type.color.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                c.name,
                style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
      ],
    );
  }
}
