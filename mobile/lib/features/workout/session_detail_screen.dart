import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import '../library/muscle_icon.dart';

/// A finished workout: stats, personal bests and every set against its
/// target. With [justFinished] it doubles as the end-of-workout summary.
class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({
    super.key,
    required this.sessionId,
    this.justFinished = false,
  });

  final int sessionId;
  final bool justFinished;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete this workout?',
      message: 'All sets logged in it are removed.',
    );
    if (!ok) return;
    await ref.read(sessionRepoProvider).delete(sessionId);
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final w = ref.watch(workoutProvider(sessionId)).value;
    final records =
        ref.watch(weightRecordsProvider(sessionId)).value ?? const {};
    if (w == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }
    final s = w.session;
    final duration = (s.endedAt ?? DateTime.now()).difference(s.startedAt);
    final exercises = w.exercises.where((e) => e.sets.isNotEmpty).toList();
    final when = DateFormat('EEEE d MMMM · HH:mm').format(s.startedAt);

    return Scaffold(
      appBar: AppBar(
        title: Text(justFinished ? 'Workout complete' : s.name),
        automaticallyImplyLeading: !justFinished,
        actions: [
          if (!justFinished)
            IconButton(
              tooltip: 'Delete workout',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _delete(context, ref),
            ),
        ],
      ),
      bottomNavigationBar: justFinished
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            )
          : null,
      body: GlowBackdrop(
        color: accent,
        secondary: records.isNotEmpty ? CycleType.bulk.color : null,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          children: [
            if (justFinished)
              FadeSlideIn(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    ProgressRing(
                      value: 1,
                      color: accent,
                      size: 132,
                      stroke: 12,
                      child: Icon(
                        records.isEmpty
                            ? Icons.check_rounded
                            : Icons.emoji_events_rounded,
                        size: 56,
                        color: records.isEmpty ? accent : CycleType.bulk.color,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(s.name, style: t.headlineMedium),
                    const SizedBox(height: 4),
                    Text(
                      records.isEmpty
                          ? 'Nice work. It\'s all saved.'
                          : records.length == 1
                          ? 'Nice work, and a new personal best!'
                          : 'Nice work, and ${records.length} new personal '
                                'bests!',
                      style: t.bodyMedium!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Text(
                  when,
                  style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
                ),
              ),
            FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              child: GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.55,
                children: [
                  StatTile(
                    icon: Icons.timer_outlined,
                    value: formatDuration(duration.inSeconds),
                    label: 'Duration',
                    color: CycleType.endurance.color,
                  ),
                  StatTile(
                    icon: Icons.stacked_bar_chart_rounded,
                    value: '${w.loggedSets}',
                    label: 'Sets',
                    color: accent,
                  ),
                  StatTile(
                    icon: Icons.scale_rounded,
                    value: formatKg(w.volumeKg),
                    label: 'Volume',
                    color: CycleType.bulk.color,
                  ),
                  StatTile(
                    icon: Icons.fitness_center_rounded,
                    value: '${exercises.length}',
                    label: 'Exercises',
                    color: CycleType.cut.color,
                  ),
                ],
              ),
            ),
            if (records.isNotEmpty) ...[
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 140),
                child: _RecordsCard(workout: w, records: records),
              ),
            ],
            const SizedBox(height: 22),
            const SectionHeader('Sets'),
            for (final (i, e) in exercises.indexed)
              FadeSlideIn.staggered(
                index: i + 2,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ExerciseSummary(
                    we: e,
                    record: records.containsKey(e.exercise.id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordsCard extends StatelessWidget {
  const _RecordsCard({required this.workout, required this.records});
  final Workout workout;
  final Map<int, double> records;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final gold = CycleType.bulk.color;
    final names = {
      for (final e in workout.exercises) e.exercise.id: e.exercise.name,
    };
    return SurfaceCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(gold.withValues(alpha: 0.2), AppColors.surface),
          AppColors.surface,
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.emoji_events_rounded, color: gold),
              const SizedBox(width: 10),
              Text('Personal bests', style: t.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          for (final MapEntry(key: id, value: kg) in records.entries)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(child: Text(names[id] ?? '', style: t.bodyLarge)),
                  Text(
                    formatKg(kg),
                    style: t.titleMedium!.copyWith(color: gold),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ExerciseSummary extends StatelessWidget {
  const _ExerciseSummary({required this.we, required this.record});
  final WorkoutExercise we;
  final bool record;

  /// Whether a set reached what was planned for it.
  static bool? metTarget(SetLog s) {
    final checks = <bool>[
      if (s.targetReps != null) (s.reps ?? 0) >= s.targetReps!,
      if (s.targetWeightKg != null) (s.weightKg ?? 0) >= s.targetWeightKg!,
      if (s.targetDurationSec != null)
        (s.durationSec ?? 0) >= s.targetDurationSec!,
      if (s.targetDistanceKm != null)
        (s.distanceKm ?? 0) >= s.targetDistanceKm!,
    ];
    return checks.isEmpty ? null : checks.every((c) => c);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = we.exercise;
    final color = e.muscle.color;
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MuscleIcon(muscle: e.muscle, size: 38),
              const SizedBox(width: 12),
              Expanded(child: Text(e.name, style: t.titleMedium)),
              if (record)
                Tag(
                  label: 'PB',
                  color: CycleType.bulk.color,
                  icon: Icons.emoji_events_rounded,
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (final s in we.sets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.16),
                    ),
                    child: Text(
                      '${s.setNumber}',
                      style: t.labelMedium!.copyWith(color: color),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      describeSet(
                        e.tracking,
                        reps: s.reps,
                        weightKg: s.weightKg,
                        durationSec: s.durationSec,
                        distanceKm: s.distanceKm,
                      ),
                      style: t.bodyLarge,
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final target = describeSet(
                        e.tracking,
                        reps: s.targetReps,
                        weightKg: s.targetWeightKg,
                        durationSec: s.targetDurationSec,
                        distanceKm: s.targetDistanceKm,
                      );
                      final met = metTarget(s);
                      return Row(
                        children: [
                          if (target.isNotEmpty)
                            Text(
                              target,
                              style: t.bodySmall!.copyWith(
                                color: AppColors.textTertiary,
                              ),
                            ),
                          if (met != null) ...[
                            const SizedBox(width: 8),
                            Icon(
                              met
                                  ? Icons.check_circle_rounded
                                  : Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: met ? color : AppColors.textTertiary,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
