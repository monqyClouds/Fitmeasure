import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/cycle_repo.dart';
import '../../domain/dates.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';

/// Hero card for the running cycle: type, week progress and suggested targets.
class CycleCard extends StatelessWidget {
  const CycleCard({super.key, required this.cycle, this.onTap});
  final Cycle cycle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final type = cycle.type;
    final color = type.color;
    final week = cycle.weekOf(DateTime.now());
    final total = cycle.totalWeeks;
    final progress = cycle.progress;

    return Pressable(
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                color.withValues(alpha: 0.22),
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
                Tag(label: type.label, color: color, icon: type.icon),
                const Spacer(),
                Text(
                  formatDateRange(cycle.startDate, cycle.endDate),
                  style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(cycle.name, style: t.headlineSmall),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Week ',
                  style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
                ),
                AnimatedCount(value: week, style: t.titleLarge),
                if (total != null)
                  Text(
                    ' of $total',
                    style: t.bodyLarge!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 16),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 900),
                curve: Motion.enter,
                builder: (context, v, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: v,
                    minHeight: 8,
                    color: color,
                    backgroundColor: AppColors.surfaceHighest,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                _Target(label: 'Sets', value: '${type.sets}'),
                _Target(label: 'Reps', value: type.repRange),
                _Target(label: 'Rest', value: '${type.restSec}s'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Target extends StatelessWidget {
  const _Target({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 4),
          Text(value, style: t.titleMedium),
        ],
      ),
    );
  }
}
