import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/plan_repo.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import '../cycles/cycle_card.dart';
import '../cycles/cycle_editor_screen.dart';
import '../cycles/cycles_screen.dart';
import '../plans/plan_screen.dart';
import '../plans/plan_visuals.dart';
import '../plans/plans_screen.dart';
import '../profiles/profile_menu_sheet.dart';
import '../workout/rest_timer.dart';
import '../workout/session_detail_screen.dart';
import '../workout/start_workout.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final cycle = ref.watch(activeCycleProvider);
    final cyclesLoaded = ref.watch(cyclesProvider).hasValue;
    final today = ref.watch(todayPlanProvider);
    final active = ref.watch(activeSessionProvider).value;
    final recent = ref.watch(recentSessionsProvider).value ?? const [];
    final accent = Theme.of(context).colorScheme.primary;

    if (profile == null) return const Scaffold();

    // Keyed by content, so cards appearing (e.g. the resume card) don't
    // shift the state of the ones after them.
    var step = 0;
    Widget stagger(Widget child, [Object? key]) => FadeSlideIn.staggered(
      key: ValueKey(key ?? child.runtimeType),
      index: step++,
      child: child,
    );

    return Scaffold(
      body: GlowBackdrop(
        color: accent,
        secondary: cycle?.type.color,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              stagger(_Header(profile: profile)),
              const SizedBox(height: 22),
              stagger(_WeekCard(recent: recent, today: today.value)),
              if (active != null) ...[
                const SizedBox(height: 14),
                stagger(_ResumeCard(session: active)),
              ],
              const SizedBox(height: 26),
              stagger(const SectionHeader("Today's workout"), 'today-header'),
              if (today.hasValue) stagger(_TodaySection(today: today.value)),
              const SizedBox(height: 26),
              if (cyclesLoaded) ...[
                stagger(const SectionHeader('Cycle'), 'cycle-header'),
                stagger(
                  cycle == null
                      ? _StartCycleCard(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CycleEditorScreen(),
                            ),
                          ),
                        )
                      : CycleCard(
                          cycle: cycle,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CyclesScreen(),
                            ),
                          ),
                        ),
                ),
              ],
              if (recent.isNotEmpty) ...[
                const SizedBox(height: 26),
                stagger(
                  const SectionHeader('Recent workouts'),
                  'recent-header',
                ),
                stagger(_VolumeCard(recent: recent)),
                const SizedBox(height: 12),
                for (final s in recent.take(5))
                  stagger(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SessionTile(summary: s),
                    ),
                    'session-${s.session.id}',
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.recent, required this.today});
  final List<SessionSummary> recent;
  final TodayPlan? today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    final monday = dateOnly(now).subtract(Duration(days: now.weekday - 1));
    final thisWeek = [
      for (final s in recent)
        if (!s.session.startedAt.isBefore(monday)) s,
    ];
    final plan = today?.plan;
    final planned = plan?.schedule == PlanSchedule.weekly
        ? {for (final d in today!.days) ?d.day.weekday}
        : <int>{};
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Text('This week', style: t.titleMedium),
              const Spacer(),
              Icon(
                Icons.local_fire_department_rounded,
                size: 18,
                color: thisWeek.isEmpty
                    ? AppColors.textTertiary
                    : CycleType.strength.color,
              ),
              const SizedBox(width: 4),
              Text(
                thisWeek.length == 1
                    ? '1 workout'
                    : '${thisWeek.length} workouts',
                style: t.labelMedium!.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 14),
          WeekStrip(
            trained: {for (final s in thisWeek) s.session.startedAt},
            planned: planned,
          ),
        ],
      ),
    );
  }
}

class _ResumeCard extends ConsumerWidget {
  const _ResumeCard({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final w = ref.watch(workoutProvider(session.id)).value;
    final done = w?.loggedSets ?? 0;
    final total = done + (w?.remainingSets ?? 0);
    return Pressable(
      onTap: () => openWorkout(context, session.id),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          gradient: LinearGradient(
            colors: [
              accent.withValues(alpha: 0.9),
              accent.withValues(alpha: 0.6),
            ],
          ),
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.3), blurRadius: 24),
          ],
        ),
        child: Row(
          children: [
            ProgressRing(
              value: total == 0 ? 0 : done / total,
              color: onColor(accent),
              size: 60,
              stroke: 6,
              child: Text(
                '$done/$total',
                style: t.labelMedium!.copyWith(color: onColor(accent)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'IN PROGRESS',
                    style: t.labelSmall!.copyWith(
                      color: onColor(accent).withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    session.name,
                    style: t.titleLarge!.copyWith(color: onColor(accent)),
                  ),
                  ElapsedText(
                    since: session.startedAt,
                    style: t.bodyMedium!.copyWith(
                      color: onColor(accent).withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: onColor(accent),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.play_arrow_rounded, color: accent, size: 28),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodaySection extends ConsumerWidget {
  const _TodaySection({required this.today});
  final TodayPlan? today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = today;
    final Widget card;
    if (plan == null) {
      card = _NoPlanCard(onCreate: () => startNewPlan(context, ref));
    } else if (plan.days.isEmpty) {
      card = _NoPlanCard(
        title: 'Add days to ${plan.plan.name}',
        message: 'Your plan has no training days yet.',
        button: 'Open plan',
        onCreate: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PlanScreen(planId: plan.plan.id)),
        ),
      );
    } else if (plan.today != null) {
      card = _WorkoutDayCard(today: plan);
    } else {
      card = _RestDayCard(today: plan);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        const SizedBox(height: 4),
        Align(
          child: TextButton.icon(
            onPressed: () => startWorkout(context, ref),
            icon: const Icon(Icons.bolt_rounded, size: 18),
            label: const Text('Start an empty workout'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Lets the user train a different day of the plan than the one scheduled.
Future<PlanDayDetail?> _pickDay(
  BuildContext context,
  TodayPlan today,
) => showModalBottomSheet<PlanDayDetail>(
  context: context,
  builder: (context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text('Train which day?', style: t.headlineSmall),
          ),
          for (final d in today.days)
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.tile),
              ),
              leading: ExerciseStack(exercises: d.exercises, max: 3),
              title: Text(d.day.name, style: t.titleMedium),
              subtitle: Text(
                [
                  if (d.day.weekday != null) weekdayNames[d.day.weekday! - 1],
                  '${d.items.length} exercises',
                ].join(' · '),
                style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
              ),
              onTap: () => Navigator.pop(context, d),
            ),
        ],
      ),
    );
  },
);

class _WorkoutDayCard extends ConsumerWidget {
  const _WorkoutDayCard({required this.today});
  final TodayPlan today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final day = today.today!;
    final done = today.doneToday;
    final shown = day.items.take(4).toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(accent.withValues(alpha: 0.2), AppColors.surface),
            AppColors.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      today.plan.name.toUpperCase(),
                      style: t.labelSmall!.copyWith(color: accent),
                    ),
                    const SizedBox(height: 4),
                    Text(day.day.name, style: t.headlineMedium),
                  ],
                ),
              ),
              if (done)
                Tag(
                  label: 'Done',
                  color: accent,
                  icon: Icons.check_circle_rounded,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Chip(
                icon: Icons.fitness_center_rounded,
                text: '${day.items.length}',
              ),
              const SizedBox(width: 8),
              _Chip(
                icon: Icons.stacked_bar_chart_rounded,
                text: '${day.totalSets} sets',
              ),
              const SizedBox(width: 8),
              _Chip(
                icon: Icons.timer_outlined,
                text: '~${day.estimatedMinutes} min',
              ),
            ],
          ),
          const SizedBox(height: 16),
          MuscleBalanceBar(exercises: day.exercises),
          if (shown.isNotEmpty) const SizedBox(height: 14),
          for (final i in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 22,
                    decoration: BoxDecoration(
                      color: i.exercise.muscle.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      i.exercise.name,
                      style: t.bodyLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    describeTargets(
                      i.exercise.tracking,
                      sets: i.item.targetSets,
                      reps: i.item.targetReps,
                      weightKg: i.item.targetWeightKg,
                      durationSec: i.item.targetDurationSec,
                      distanceKm: i.item.targetDistanceKm,
                    ),
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          if (day.items.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                '+ ${day.items.length - shown.length} more',
                style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
              ),
            ),
          const SizedBox(height: 18),
          if (day.items.isEmpty)
            OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlanScreen(planId: today.plan.id),
                ),
              ),
              child: const Text('Add exercises to this day'),
            )
          else if (done)
            OutlinedButton.icon(
              onPressed: () => startWorkout(context, ref, day: day),
              icon: const Icon(Icons.replay_rounded),
              label: const Text('Train it again'),
            )
          else
            FilledButton.icon(
              onPressed: () => startWorkout(context, ref, day: day),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Start workout'),
            ),
          if (today.days.length > 1)
            TextButton(
              onPressed: () async {
                final other = await _pickDay(context, today);
                if (other != null && context.mounted) {
                  await startWorkout(context, ref, day: other);
                }
              },
              child: const Text('Train a different day'),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Text(text, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _RestDayCard extends ConsumerWidget {
  const _RestDayCard({required this.today});
  final TodayPlan today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    const moon = Color(0xFFA99BFF);
    final next = today.next;
    return SurfaceCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(moon.withValues(alpha: 0.16), AppColors.surface),
          AppColors.surface,
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: moon.withValues(alpha: 0.16),
                  boxShadow: [
                    BoxShadow(
                      color: moon.withValues(alpha: 0.3),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.nightlight_round,
                  color: moon,
                  size: 30,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Rest day', style: t.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      next == null
                          ? 'Recover well.'
                          : 'Next up: ${next.day.name} on '
                                '${weekdayNames[(next.day.weekday ?? 1) - 1]}',
                      style: t.bodyMedium!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: () async {
              final day = await _pickDay(context, today);
              if (day != null && context.mounted) {
                await startWorkout(context, ref, day: day);
              }
            },
            child: const Text('Train anyway'),
          ),
        ],
      ),
    );
  }
}

class _NoPlanCard extends StatelessWidget {
  const _NoPlanCard({
    required this.onCreate,
    this.title = 'Plan your training',
    this.message =
        'Set up the days you train and what you do on each. Today will '
        'then show your workout, ready to log.',
    this.button = 'Create a plan',
  });

  final VoidCallback onCreate;
  final String title;
  final String message;
  final String button;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final (i, m) in const [
                MuscleGroup.chest,
                MuscleGroup.back,
                MuscleGroup.legs,
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          m.color.withValues(alpha: 0.3),
                          m.color.withValues(alpha: 0.08),
                        ],
                      ),
                    ),
                    child: Icon(
                      [
                        Icons.fitness_center_rounded,
                        Icons.rowing_rounded,
                        Icons.directions_run_rounded,
                      ][i],
                      color: m.color,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 18),
          Text(title, style: t.titleLarge),
          const SizedBox(height: 6),
          Text(
            message,
            style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onCreate,
            style: FilledButton.styleFrom(backgroundColor: accent),
            icon: const Icon(Icons.edit_calendar_rounded),
            label: Text(button),
          ),
        ],
      ),
    );
  }
}

class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.recent});
  final List<SessionSummary> recent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final last = recent.take(10).toList().reversed.toList();
    final totalSets = recent.take(10).fold(0, (n, s) => n + s.sets);
    return SurfaceCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VOLUME PER WORKOUT',
                      style: t.labelSmall!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${NumberFormat.decimalPattern().format(recent.first.volumeKg.round())} kg',
                      style: t.headlineSmall,
                    ),
                  ],
                ),
              ),
              Text(
                '$totalSets sets in ${last.length} workouts',
                style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          MiniBarChart(
            values: [for (final s in last) s.volumeKg],
            color: accent,
          ),
        ],
      ),
    );
  }
}

class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.summary});
  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final s = summary.session;
    final minutes = summary.duration?.inMinutes ?? 0;
    return Pressable(
      borderRadius: Radii.tile,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: s.id)),
      ),
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 54,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${s.startedAt.day}', style: t.titleLarge),
                  Text(
                    DateFormat('MMM').format(s.startedAt).toUpperCase(),
                    style: t.labelSmall!.copyWith(color: accent),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name, style: t.titleMedium),
                  const SizedBox(height: 3),
                  Text(
                    '$minutes min · ${summary.sets} sets',
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (summary.volumeKg > 0)
              Text(
                '${NumberFormat.decimalPattern().format(summary.volumeKg.round())} kg',
                style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
              ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${greeting(now)},',
                style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 2),
              Text(
                profile.name,
                style: t.headlineMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Pressable(
          borderRadius: 30,
          onTap: () => showProfileMenu(context),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: ProfileAvatar(
              name: profile.name,
              color: Color(profile.color),
              size: 48,
            ),
          ),
        ),
      ],
    );
  }
}

class _StartCycleCard extends StatelessWidget {
  const _StartCycleCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
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
                accent.withValues(alpha: 0.20),
                AppColors.surface,
              ),
              AppColors.surface,
            ],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start a cycle', style: t.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Bulk, cut, strength, endurance or an ongoing routine. '
                    'Your targets and charts follow it.',
                    style: t.bodyMedium!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Icon(Icons.arrow_forward_rounded, color: onColor(accent)),
            ),
          ],
        ),
      ),
    );
  }
}
