import '../share/share_actions.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/plan_repo.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import 'day_editor_screen.dart';
import 'day_sheet.dart';
import 'plan_visuals.dart';

class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key, required this.planId});
  final int planId;

  @override
  ConsumerState<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends ConsumerState<PlanScreen> {
  /// Day order after a drag, shown until the database catches up.
  List<int>? _order;

  void _openDay(int dayId) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => DayEditorScreen(planId: widget.planId, dayId: dayId),
    ),
  );

  Future<void> _addDay(Plan plan, List<PlanDayDetail> days) async {
    final input = await showDaySheet(
      context,
      schedule: plan.schedule,
      name: plan.schedule == PlanSchedule.rotation
          ? 'Day ${days.length + 1}'
          : null,
      taken: {for (final d in days) ?d.day.weekday},
    );
    if (input == null) return;
    final id = await ref
        .read(planRepoProvider)
        .addDay(planId: plan.id, name: input.name, weekday: input.weekday);
    if (mounted) _openDay(id);
  }

  Future<void> _menu(String action, Plan plan) async {
    final repo = ref.read(planRepoProvider);
    switch (action) {
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename plan',
          initial: plan.name,
        );
        if (name != null) await repo.renamePlan(plan.id, name);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: 'Delete ${plan.name}?',
          message:
              'Its days and targets are removed. Workouts you logged '
              'with it are kept.',
        );
        if (!ok) return;
        await repo.deletePlan(plan.id);
        if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final plan = ref.watch(planProvider(widget.planId)).value;
    final loaded = ref.watch(planDaysProvider(widget.planId)).value;
    if (plan == null || loaded == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }

    var days = loaded;
    final order = _order;
    if (order != null) {
      final byId = {for (final d in loaded) d.day.id: d};
      if (order.length == loaded.length && order.every(byId.containsKey)) {
        days = [for (final id in order) byId[id]!];
      }
    }
    final rotation = plan.schedule == PlanSchedule.rotation;
    final exercises = [for (final d in days) ...d.exercises];
    final sets = days.fold(0, (n, d) => n + d.totalSets);

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FadeSlideIn(
          child: SurfaceCard(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  accent.withValues(alpha: 0.18),
                  AppColors.surface,
                ),
                AppColors.surface,
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        rotation
                            ? 'Rotation: train the next day each time'
                            : 'Weekly: each day on its weekday',
                        style: t.bodyMedium!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    if (plan.active)
                      Tag(
                        label: 'Active',
                        color: accent,
                        icon: Icons.bolt_rounded,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                ScheduleStrip(
                  schedule: plan.schedule,
                  days: [for (final d in days) d.day],
                ),
                const SizedBox(height: 18),
                MuscleBalanceBar(exercises: exercises),
                if (!plan.active) ...[
                  const SizedBox(height: 18),
                  FilledButton.tonalIcon(
                    onPressed: () => ref.read(planRepoProvider).setActive(plan),
                    icon: const Icon(Icons.bolt_rounded),
                    label: const Text('Follow this plan on Today'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        FadeSlideIn(
          delay: const Duration(milliseconds: 60),
          child: Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.event_repeat_rounded,
                  value: '${days.length}',
                  label: 'Days',
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.fitness_center_rounded,
                  value: '${exercises.length}',
                  label: 'Exercises',
                  color: CycleType.endurance.color,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.stacked_bar_chart_rounded,
                  value: '$sets',
                  label: rotation ? 'Sets per round' : 'Sets per week',
                  color: CycleType.bulk.color,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        SectionHeader(
          'Training days',
          trailing: rotation && days.length > 1
              ? Text(
                  'Drag to reorder',
                  style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
                )
              : null,
        ),
        if (days.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: EmptyState(
              icon: Icons.event_note_rounded,
              title: 'No days yet',
              message: rotation
                  ? 'Add the workouts you rotate through, like Push, Pull '
                        'and Legs.'
                  : 'Add a day for each weekday you train.',
            ),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(plan.name),
        actions: [
          IconButton(
            tooltip: 'Share plan',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => sharePlan(context, ref, plan),
          ),
          PopupMenuButton<String>(
            onSelected: (a) => _menu(a, plan),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete plan')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addDay(plan, days),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add day'),
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        header: header,
        buildDefaultDragHandles: false,
        itemCount: days.length,
        onReorderItem: (from, to) {
          if (!rotation) return;
          final ids = [for (final d in days) d.day.id];
          final id = ids.removeAt(from);
          ids.insert(to, id);
          setState(() => _order = ids);
          ref.read(planRepoProvider).reorderDays(ids);
        },
        proxyDecorator: (child, _, _) => Material(
          color: Colors.transparent,
          elevation: 8,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(Radii.card),
          child: child,
        ),
        itemBuilder: (context, i) {
          final d = days[i];
          final card = _DayCard(
            detail: d,
            index: i,
            rotation: rotation,
            onTap: () => _openDay(d.day.id),
          );
          return Padding(
            key: ValueKey(d.day.id),
            padding: const EdgeInsets.only(bottom: 12),
            child: rotation
                ? ReorderableDelayedDragStartListener(index: i, child: card)
                : card,
          );
        },
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.detail,
    required this.index,
    required this.rotation,
    required this.onTap,
  });

  final PlanDayDetail detail;
  final int index;
  final bool rotation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final day = detail.day;
    final badge = rotation
        ? '${index + 1}'
        : weekdayShort[(day.weekday ?? 1) - 1].toUpperCase();

    return Pressable(
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accent, Color.lerp(accent, Colors.black, 0.35)!],
                    ),
                  ),
                  child: Text(
                    badge,
                    style: t.titleSmall!.copyWith(
                      color: onColor(accent),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(day.name, style: t.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        detail.items.isEmpty
                            ? 'No exercises yet'
                            : '${detail.items.length} exercises · '
                                  '${detail.totalSets} sets · '
                                  '~${detail.estimatedMinutes} min',
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (rotation)
                  const Icon(
                    Icons.drag_indicator_rounded,
                    color: AppColors.textTertiary,
                  ),
              ],
            ),
            if (detail.items.isNotEmpty) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  ExerciseStack(exercises: detail.exercises),
                  const SizedBox(width: 14),
                  Expanded(
                    child: MuscleBalanceBar(
                      exercises: detail.exercises,
                      showLegend: false,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
