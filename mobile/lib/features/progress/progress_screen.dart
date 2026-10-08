import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/measurement_repo.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../domain/strength.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/visuals.dart';
import '../body/log_measurements_screen.dart';
import '../body/measurement_detail_screen.dart';
import '../body/measurement_style.dart';
import '../body/measurement_types_screen.dart';
import 'exercise_progress_screen.dart';

/// Training activity, body measurements, strength per exercise and records.
class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  static DateTime _monday(DateTime d) =>
      dateOnly(d).subtract(Duration(days: d.weekday - 1));

  /// Consecutive weeks with at least one workout, counting back from this
  /// week (or last week, if nothing's been done yet this week).
  static int weekStreak(Iterable<DateTime> dates, DateTime now) {
    final weeks = {for (final d in dates) _monday(d)};
    var week = _monday(now);
    if (!weeks.contains(week)) week = week.subtract(const Duration(days: 7));
    var streak = 0;
    while (weeks.contains(week)) {
      streak++;
      week = week.subtract(const Duration(days: 7));
    }
    return streak;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final async = ref.watch(allSessionsProvider);
    final all = async.value ?? const <SessionSummary>[];
    final now = DateTime.now();
    final number = NumberFormat.decimalPattern();

    final perDay = <DateTime, double>{};
    for (final s in all) {
      final d = dateOnly(s.session.startedAt);
      perDay[d] = (perDay[d] ?? 0) + s.sets;
    }
    final thisMonday = _monday(now);
    final weeklyVolume = [
      for (var w = 7; w >= 0; w--)
        all
            .where(
              (s) =>
                  _monday(s.session.startedAt) ==
                  thisMonday.subtract(Duration(days: 7 * w)),
            )
            .fold<double>(0, (v, s) => v + s.volumeKg),
    ];
    final totalMinutes = all.fold(
      0,
      (m, s) => m + (s.duration?.inMinutes ?? 0),
    );
    final streak = weekStreak([for (final s in all) s.session.startedAt], now);
    final measurements = ref.watch(measurementsProvider).value ?? const [];
    final trends = ref.watch(strengthTrendsProvider).value ?? const [];
    final cycles = ref.watch(cyclesProvider).value ?? const <Cycle>[];
    final records = recentRecords(trends);

    return Scaffold(
      body: GlowBackdrop(
        color: accent,
        secondary: CycleType.cut.color,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              FadeSlideIn(child: Text('Progress', style: t.headlineMedium)),
              const SizedBox(height: 4),
              Text(
                all.isEmpty
                    ? 'Your body and training, at a glance'
                    : 'Training since ${formatDate(all.last.session.startedAt)}',
                style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 22),
              if (all.isNotEmpty) ...[
                FadeSlideIn(
                  child: _StreakCard(streak: streak, total: all.length),
                ),
                const SizedBox(height: 12),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.95,
                    children: [
                      StatTile(
                        icon: Icons.timer_outlined,
                        value: totalMinutes >= 120
                            ? '${(totalMinutes / 60).toStringAsFixed(1)} h'
                            : '$totalMinutes min',
                        label: 'Time trained',
                        color: CycleType.endurance.color,
                      ),
                      StatTile(
                        icon: Icons.stacked_bar_chart_rounded,
                        value: number.format(all.fold(0, (n, s) => n + s.sets)),
                        label: 'Sets',
                        color: accent,
                      ),
                      StatTile(
                        icon: Icons.scale_rounded,
                        value:
                            '${number.format((all.fold<double>(0, (v, s) => v + s.volumeKg) / 1000).round())} t',
                        label: 'Lifted',
                        color: CycleType.bulk.color,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
              ],
              SectionHeader(
                'Body',
                trailing: IconButton(
                  tooltip: 'Edit measurement types',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.tune_rounded,
                    size: 20,
                    color: AppColors.textTertiary,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MeasurementTypesScreen(),
                    ),
                  ),
                ),
              ),
              FadeSlideIn(
                delay: const Duration(milliseconds: 100),
                child: _BodySection(series: measurements, cycles: cycles),
              ),
              const SizedBox(height: 22),
              SectionHeader(
                'Strength',
                trailing: trends.length > 5
                    ? GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const StrengthListScreen(),
                          ),
                        ),
                        child: Text(
                          'SEE ALL ${trends.length}',
                          style: t.labelSmall!.copyWith(color: accent),
                        ),
                      )
                    : null,
              ),
              if (trends.isEmpty)
                _Hint(
                  icon: Icons.fitness_center_rounded,
                  text:
                      'Finish a workout and each exercise gets its own '
                      'strength chart here.',
                )
              else
                for (final (i, tr) in trends.take(5).indexed)
                  FadeSlideIn.staggered(
                    index: i + 3,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: StrengthTile(trend: tr),
                    ),
                  ),
              if (records.isNotEmpty) ...[
                const SizedBox(height: 12),
                const SectionHeader('Records'),
                SizedBox(
                  height: 132,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) =>
                        _RecordCard(record: records[i]),
                  ),
                ),
              ],
              if (all.isNotEmpty) ...[
                const SizedBox(height: 22),
                const SectionHeader('Training calendar'),
                SurfaceCard(
                  padding: const EdgeInsets.all(18),
                  child: TrainingHeatmap(values: perDay, color: accent),
                ),
                const SizedBox(height: 22),
                const SectionHeader('Weekly volume'),
                SurfaceCard(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${number.format(weeklyVolume.last.round())} kg',
                        style: t.headlineSmall,
                      ),
                      Text(
                        'this week',
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      MiniBarChart(
                        values: weeklyVolume,
                        color: CycleType.bulk.color,
                        height: 110,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatShortDate(
                              thisMonday.subtract(const Duration(days: 49)),
                            ),
                            style: t.labelSmall!.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                          Text(
                            'This week',
                            style: t.labelSmall!.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.total});
  final int streak;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fire = CycleType.strength.color;
    return SurfaceCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(fire.withValues(alpha: 0.22), AppColors.surface),
          AppColors.surface,
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fire.withValues(alpha: 0.18),
              boxShadow: [
                BoxShadow(color: fire.withValues(alpha: 0.35), blurRadius: 24),
              ],
            ),
            child: Icon(
              Icons.local_fire_department_rounded,
              color: fire,
              size: 34,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    AnimatedCount(value: streak, style: t.displaySmall),
                    const SizedBox(width: 6),
                    Text('week streak', style: t.titleMedium),
                  ],
                ),
                Text(
                  total == 1 ? '1 workout logged' : '$total workouts logged',
                  style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A new heaviest set for an exercise.
typedef RecentRecord = ({ExerciseTrend trend, Best<double> best, int? reps});

/// Heaviest-set records, newest first. A record from an exercise's very first
/// workout isn't a record yet, so it's left out.
List<RecentRecord> recentRecords(List<ExerciseTrend> trends) {
  final out = <RecentRecord>[];
  for (final tr in trends) {
    if (tr.history.length < 2) continue;
    final r = ExerciseRecords.from(tr.history);
    final h = r.heaviest;
    if (h == null || h.date == tr.history.first.date) continue;
    out.add((trend: tr, best: h, reps: r.repsAtHeaviest));
  }
  out.sort((a, b) => b.best.date.compareTo(a.best.date));
  return out.take(10).toList();
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record});
  final RecentRecord record;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final gold = CycleType.bulk.color;
    final e = record.trend.exercise;
    return Pressable(
      borderRadius: Radii.tile,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ExerciseProgressScreen(exerciseId: e.id),
        ),
      ),
      child: Ink(
        width: 156,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.tile),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(gold.withValues(alpha: 0.2), AppColors.surface),
              AppColors.surface,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.emoji_events_rounded, color: gold, size: 20),
                const Spacer(),
                Text(
                  formatShortDate(record.best.date),
                  style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ),
            const Spacer(),
            Text(
              record.reps == null
                  ? formatKg(record.best.value)
                  : '${formatKg(record.best.value)} × ${record.reps}',
              style: t.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              e.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textTertiary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium!
                  .copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodySection extends StatelessWidget {
  const _BodySection({required this.series, required this.cycles});
  final List<MeasurementSeries> series;
  final List<Cycle> cycles;

  void _open(BuildContext context, MeasurementSeries s) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MeasurementDetailScreen(typeId: s.type.id),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hero = series.firstOrNull;
    final others = [
      for (final s in series.skip(1))
        if (s.entries.isNotEmpty) s,
    ];
    final logButton = FilledButton.tonalIcon(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LogMeasurementsScreen()),
      ),
      icon: const Icon(Icons.add_rounded),
      label: const Text('Log measurements'),
    );
    if (hero == null) return logButton;

    final style = measurementStyle(hero.type);
    final now = DateTime.now();
    final since = dateOnly(now).subtract(const Duration(days: 91));
    final recent = [
      for (final e in hero.entries)
        if (!e.recordedAt.isBefore(since)) (e.recordedAt, e.value),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Pressable(
          onTap: () => _open(context, hero),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.card),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    style.color.withValues(alpha: 0.16),
                    AppColors.surface,
                  ),
                  AppColors.surface,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(style.icon, color: style.color, size: 20),
                    const SizedBox(width: 8),
                    Text(hero.type.name, style: t.titleMedium),
                    const Spacer(),
                    ChangePill(
                      change: hero.changeOver(30, now),
                      unit: hero.type.unit,
                      suffix: '30d',
                      color: style.color,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  hero.latest == null
                      ? 'Not logged yet'
                      : formatMeasurement(hero.latest!.value, hero.type.unit),
                  style: hero.latest == null ? t.titleLarge : t.displaySmall,
                ),
                const SizedBox(height: 8),
                if (hero.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Log it regularly to see the trend, shaded by your '
                      'cycles.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  TrendChart(
                    points: recent.isEmpty
                        ? [(hero.latest!.recordedAt, hero.latest!.value)]
                        : recent,
                    color: style.color,
                    cycles: cycles,
                    unit: hero.type.unit,
                    height: 150,
                  ),
              ],
            ),
          ),
        ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
            children: [
              for (final s in others)
                _MeasurementTile(series: s, onTap: () => _open(context, s)),
            ],
          ),
        ],
        const SizedBox(height: 12),
        logButton,
      ],
    );
  }
}

class _MeasurementTile extends StatelessWidget {
  const _MeasurementTile({required this.series, required this.onTap});
  final MeasurementSeries series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final style = measurementStyle(series.type);
    final latest = series.latest!;
    final change = formatChange(
      series.changeOver(30, DateTime.now()),
      series.type.unit,
    );
    return Pressable(
      borderRadius: Radii.tile,
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(style.icon, size: 16, color: style.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    series.type.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelMedium!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              formatMeasurement(latest.value, series.type.unit),
              style: t.titleLarge,
            ),
            if (change != null)
              Text(change, style: t.labelSmall!.copyWith(color: style.color)),
            const Spacer(),
            TrendChart(
              points: [for (final e in series.entries) (e.recordedAt, e.value)],
              color: style.color,
              sparkline: true,
              height: 30,
            ),
          ],
        ),
      ),
    );
  }
}
