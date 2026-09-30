import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';

/// Training activity so far. Body measurements and per-exercise strength
/// charts join this screen in phase 3.
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
                    ? 'Your training, at a glance'
                    : 'Since ${formatDate(all.last.session.startedAt)}',
                style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 22),
              if (async.hasValue && all.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: EmptyState(
                    icon: Icons.insights_rounded,
                    title: 'Nothing to chart yet',
                    message:
                        'Finish your first workout and your training '
                        'calendar, streak and volume show up here.',
                  ),
                )
              else if (all.isNotEmpty) ...[
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
                const SectionHeader('Training calendar'),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 120),
                  child: SurfaceCard(
                    padding: const EdgeInsets.all(18),
                    child: TrainingHeatmap(values: perDay, color: accent),
                  ),
                ),
                const SizedBox(height: 22),
                const SectionHeader('Weekly volume'),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 180),
                  child: SurfaceCard(
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
                ),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  const Icon(
                    Icons.straighten_rounded,
                    size: 16,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Body measurements and strength trends per exercise '
                      'arrive in the next build.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
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
