import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../domain/strength.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/visuals.dart';
import '../body/measurement_detail_screen.dart';
import '../library/muscle_icon.dart';

/// Something to chart for an exercise.
enum StrengthMetric {
  e1rm('Est. 1RM', 'Estimated 1-rep max'),
  heaviest('Heaviest', 'Heaviest set'),
  volume('Volume', 'Volume per workout'),
  reps('Reps', 'Most reps in a set'),
  time('Time', 'Longest set'),
  distance('Distance', 'Farthest');

  const StrengthMetric(this.short, this.title);
  final String short;
  final String title;

  double? of(ExerciseSessionStat s) => switch (this) {
    e1rm => s.bestE1rm,
    heaviest => s.bestWeightKg,
    volume => s.volumeKg > 0 ? s.volumeKg : null,
    reps => s.maxReps?.toDouble(),
    time => s.bestDurationSec?.toDouble(),
    distance => s.bestDistanceKm,
  };

  String format(double v) => switch (this) {
    e1rm || heaviest => formatKg(double.parse(v.toStringAsFixed(1))),
    volume => '${NumberFormat.decimalPattern().format(v.round())} kg',
    reps => '${v.round()} reps',
    time => formatDuration(v.round()),
    distance => formatKm(double.parse(v.toStringAsFixed(2))),
  };

  /// The metrics that make sense for [trend], headline first.
  static List<StrengthMetric> forTrend(ExerciseTrend trend) {
    bool has(StrengthMetric m) => trend.history.any((s) => m.of(s) != null);
    return [
      for (final m in switch (trend.exercise.tracking) {
        TrackingType.reps => [e1rm, heaviest, volume, reps],
        TrackingType.time => [time],
        TrackingType.distance => [distance, time],
      })
        if (has(m)) m,
    ];
  }
}

/// A compact row for an exercise's progress: headline value, sparkline and
/// recent change.
class StrengthTile extends StatelessWidget {
  const StrengthTile({super.key, required this.trend});
  final ExerciseTrend trend;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = trend.exercise;
    final metrics = StrengthMetric.forTrend(trend);
    final metric = metrics.firstOrNull;
    final points = metric == null
        ? const <(DateTime, double)>[]
        : [
            for (final s in trend.history)
              if (metric.of(s) case final v?) (s.date, v),
          ];
    final change = trend.changeOver(30, DateTime.now());
    return Pressable(
      borderRadius: Radii.tile,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ExerciseProgressScreen(exerciseId: e.id),
        ),
      ),
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          children: [
            MuscleIcon(muscle: e.muscle, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.name,
                    style: t.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    metric == null || points.isEmpty
                        ? '${trend.history.length} workouts'
                        : '${metric.short} ${metric.format(points.last.$2)}',
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 76,
              child: TrendChart(
                points: points,
                color: e.muscle.color,
                sparkline: true,
                height: 34,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 52, child: _PercentChange(change: change)),
          ],
        ),
      ),
    );
  }
}

class _PercentChange extends StatelessWidget {
  const _PercentChange({required this.change});
  final double? change;

  @override
  Widget build(BuildContext context) {
    final c = change;
    if (c == null) return const SizedBox.shrink();
    final pct = (c * 100).round();
    final color = pct > 0
        ? const Color(0xFFB8F34A)
        : pct < 0
        ? AppColors.danger
        : AppColors.textTertiary;
    return Text(
      pct == 0 ? '0%' : '${pct > 0 ? '+' : '−'}${pct.abs()}%',
      textAlign: TextAlign.right,
      style: Theme.of(context).textTheme.labelMedium!.copyWith(color: color),
    );
  }
}

/// Every exercise that has been logged, most recent first.
class StrengthListScreen extends ConsumerWidget {
  const StrengthListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trends = ref.watch(strengthTrendsProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Strength')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        itemCount: trends.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => FadeSlideIn.staggered(
          index: i,
          child: StrengthTile(trend: trends[i]),
        ),
      ),
    );
  }
}

/// One exercise over time: chart by metric, records and per-workout history.
class ExerciseProgressScreen extends ConsumerStatefulWidget {
  const ExerciseProgressScreen({super.key, required this.exerciseId});
  final int exerciseId;

  @override
  ConsumerState<ExerciseProgressScreen> createState() =>
      _ExerciseProgressScreenState();
}

class _ExerciseProgressScreenState
    extends ConsumerState<ExerciseProgressScreen> {
  StrengthMetric? _metric;
  int? _rangeDays;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final exercise = ref.watch(exerciseProvider(widget.exerciseId)).value;
    final trend = ref.watch(exerciseTrendProvider(widget.exerciseId));
    final cycles = ref.watch(cyclesProvider).value ?? const <Cycle>[];
    if (exercise == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }
    final color = exercise.muscle.color;
    final tr = trend.value;

    return Scaffold(
      appBar: AppBar(title: Text(exercise.name)),
      body: GlowBackdrop(
        color: color,
        child: tr == null
            ? trend.hasValue
                  ? const EmptyState(
                      icon: Icons.insights_rounded,
                      title: 'No history yet',
                      message:
                          'Finish a workout with this exercise and its '
                          'progress shows up here.',
                    )
                  : const SizedBox.shrink()
            : _body(context, t, tr, color, cycles),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    TextTheme t,
    ExerciseTrend trend,
    Color color,
    List<Cycle> cycles,
  ) {
    final metrics = StrengthMetric.forTrend(trend);
    final metric = metrics.contains(_metric) ? _metric! : metrics.first;
    final from = _rangeDays == null
        ? null
        : dateOnly(DateTime.now()).subtract(Duration(days: _rangeDays!));
    final points = [
      for (final s in trend.history)
        if (from == null || !s.date.isBefore(from))
          if (metric.of(s) case final v?) (s.date, v),
    ];
    final all = [for (final s in trend.history) ?metric.of(s)];
    final records = ExerciseRecords.from(trend.history);
    final e = trend.exercise;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
      children: [
        FadeSlideIn(
          child: Row(
            children: [
              MuscleIcon(muscle: e.muscle, size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.title.toUpperCase(),
                      style: t.labelSmall!.copyWith(color: color),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      all.isEmpty ? '–' : metric.format(all.last),
                      style: t.headlineMedium,
                    ),
                    Text(
                      'Best ${all.isEmpty ? '–' : metric.format(all.reduce((a, b) => a > b ? a : b))}'
                      ' · ${trend.history.length} workouts',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (metrics.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final m in metrics)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(m.short),
                      selected: m == metric,
                      selectedColor: color.withValues(alpha: 0.22),
                      onSelected: (_) => setState(() => _metric = m),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delay: const Duration(milliseconds: 60),
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: RangeSelector(
                    value: _rangeDays,
                    color: color,
                    onChanged: (d) => setState(() => _rangeDays = d),
                  ),
                ),
                const SizedBox(height: 16),
                TrendChart(
                  points: points,
                  color: color,
                  cycles: cycles,
                  height: 220,
                  format: metric.format,
                ),
                if (points.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: CycleLegend(cycles: cycles, from: points.first.$1),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        const SectionHeader('Personal records'),
        FadeSlideIn(
          delay: const Duration(milliseconds: 120),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.45,
            children: [
              if (records.bestE1rm case final r?)
                _RecordTile(
                  label: 'Est. 1-rep max',
                  value: StrengthMetric.e1rm.format(r.value),
                  date: r.date,
                ),
              if (records.heaviest case final r?)
                _RecordTile(
                  label: 'Heaviest set',
                  value: records.repsAtHeaviest == null
                      ? formatKg(r.value)
                      : '${formatKg(r.value)} × ${records.repsAtHeaviest}',
                  date: r.date,
                ),
              if (records.mostVolume case final r?)
                _RecordTile(
                  label: 'Best workout volume',
                  value: StrengthMetric.volume.format(r.value),
                  date: r.date,
                ),
              if (records.mostReps case final r?)
                _RecordTile(
                  label: 'Most reps',
                  value: '${r.value}',
                  date: r.date,
                ),
              if (records.longest case final r?)
                _RecordTile(
                  label: 'Longest set',
                  value: formatDuration(r.value),
                  date: r.date,
                ),
              if (records.farthest case final r?)
                _RecordTile(
                  label: 'Farthest',
                  value: formatKm(r.value),
                  date: r.date,
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const SectionHeader('Workouts'),
        for (final s in trend.history.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _HistoryRow(stat: s, tracking: e.tracking, color: color),
          ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.label,
    required this.value,
    required this.date,
  });

  final String label;
  final String value;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final gold = CycleType.bulk.color;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.tile),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(gold.withValues(alpha: 0.12), AppColors.surface),
            AppColors.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.emoji_events_rounded, size: 16, color: gold),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelMedium!.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: t.titleLarge),
          ),
          Text(
            formatDate(date),
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.stat,
    required this.tracking,
    required this.color,
  });

  final ExerciseSessionStat stat;
  final TrackingType tracking;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final best = switch (tracking) {
      TrackingType.reps =>
        stat.bestWeightKg != null
            ? describeSet(
                tracking,
                reps: stat.repsAtBestWeight,
                weightKg: stat.bestWeightKg,
              )
            : stat.maxReps == null
            ? ''
            : '${stat.maxReps} reps',
      TrackingType.time =>
        stat.bestDurationSec == null
            ? ''
            : formatDuration(stat.bestDurationSec!),
      TrackingType.distance => describeSet(
        tracking,
        distanceKm: stat.bestDistanceKm,
        durationSec: stat.bestDurationSec,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${stat.date.day}', style: t.titleSmall),
                Text(
                  DateFormat('MMM').format(stat.date).toUpperCase(),
                  style: t.labelSmall!.copyWith(color: color, fontSize: 9),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(best.isEmpty ? '–' : 'Best $best', style: t.titleSmall),
                Text(
                  [
                    '${stat.sets} sets',
                    if (stat.volumeKg > 0)
                      StrengthMetric.volume.format(stat.volumeKg),
                  ].join(' · '),
                  style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (stat.bestE1rm != null)
            Text(
              '1RM ~${formatNumber(stat.bestE1rm!.roundToDouble())}',
              style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
            ),
        ],
      ),
    );
  }
}
