import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';

/// A segmented bar showing how a set of exercises splits across muscle
/// groups, with the biggest groups labelled underneath.
class MuscleBalanceBar extends StatelessWidget {
  const MuscleBalanceBar({
    super.key,
    required this.exercises,
    this.showLegend = true,
  });

  final List<Exercise> exercises;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final counts = <MuscleGroup, int>{};
    for (final e in exercises) {
      counts[e.muscle] = (counts[e.muscle] ?? 0) + 1;
    }
    final groups = counts.entries.toList()..sort((a, b) => b.value - a.value);
    if (groups.isEmpty) {
      return Container(
        height: 8,
        decoration: BoxDecoration(
          color: AppColors.surfaceHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final (i, g) in groups.indexed) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: g.value,
                    child: ColoredBox(color: g.key.color),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showLegend) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (final g in groups.take(4))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: g.key.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      g.key.label,
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A plan's shape at a glance: the week with training days lit for weekly
/// plans, or the numbered cycle of days for rotations.
class ScheduleStrip extends StatelessWidget {
  const ScheduleStrip({
    super.key,
    required this.schedule,
    required this.days,
    this.color,
    this.highlightDayId,
  });

  final PlanSchedule schedule;
  final List<PlanDay> days;
  final Color? color;
  final int? highlightDayId;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = color ?? Theme.of(context).colorScheme.primary;
    if (schedule == PlanSchedule.weekly) {
      final byWeekday = {for (final d in days) d.weekday: d};
      return Row(
        children: [
          for (var wd = 1; wd <= 7; wd++) ...[
            if (wd > 1) const SizedBox(width: 5),
            Expanded(
              child: Builder(
                builder: (context) {
                  final d = byWeekday[wd];
                  final lit = d != null;
                  final hi = lit && d.id == highlightDayId;
                  return AnimatedContainer(
                    duration: Motion.medium,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: lit
                          ? accent.withValues(alpha: hi ? 1 : 0.22)
                          : AppColors.surfaceHigh,
                    ),
                    child: Text(
                      weekdayShort[wd - 1].substring(0, 1),
                      style: t.labelMedium!.copyWith(
                        color: hi
                            ? onColor(accent)
                            : lit
                            ? accent
                            : AppColors.textTertiary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, d) in days.indexed) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: AppColors.textTertiary,
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: d.id == highlightDayId
                    ? accent
                    : accent.withValues(alpha: 0.16),
              ),
              child: Text(
                d.name,
                style: t.labelMedium!.copyWith(
                  color: d.id == highlightDayId ? onColor(accent) : accent,
                ),
              ),
            ),
          ],
          if (days.isNotEmpty) ...[
            const SizedBox(width: 6),
            const Icon(
              Icons.replay_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
          ],
        ],
      ),
    );
  }
}

/// Stacked muscle icons of the first few exercises, e.g. on day cards.
class ExerciseStack extends StatelessWidget {
  const ExerciseStack({super.key, required this.exercises, this.max = 5});
  final List<Exercise> exercises;
  final int max;

  @override
  Widget build(BuildContext context) {
    final shown = exercises.take(max).toList();
    const size = 30.0;
    const step = 20.0;
    final extra = exercises.length - shown.length;
    return SizedBox(
      height: size,
      width: shown.isEmpty
          ? 0
          : size + step * (shown.length - 1) + (extra > 0 ? step + 6 : 0),
      child: Stack(
        children: [
          for (final (i, e) in shown.indexed)
            Positioned(
              left: i * step,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.alphaBlend(
                    e.muscle.color.withValues(alpha: 0.25),
                    AppColors.surface,
                  ),
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
                child: Icon(
                  Icons.fitness_center_rounded,
                  size: 13,
                  color: e.muscle.color,
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceHighest,
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
                child: Text(
                  '+$extra',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
