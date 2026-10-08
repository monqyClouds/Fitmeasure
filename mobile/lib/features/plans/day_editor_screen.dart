import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/plan_repo.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import '../library/exercise_picker_screen.dart';
import '../library/muscle_icon.dart';
import 'day_sheet.dart';
import 'plan_visuals.dart';
import 'targets_sheet.dart';

/// The exercises of one plan day and their targets.
class DayEditorScreen extends ConsumerStatefulWidget {
  const DayEditorScreen({super.key, required this.planId, required this.dayId});
  final int planId;
  final int dayId;

  @override
  ConsumerState<DayEditorScreen> createState() => _DayEditorScreenState();
}

class _DayEditorScreenState extends ConsumerState<DayEditorScreen> {
  List<int>? _order;

  Future<void> _addExercises(PlanDayDetail detail) async {
    final picked = await pickExercises(
      context,
      exclude: {for (final i in detail.items) i.exercise.id},
    );
    if (picked == null || picked.isEmpty) return;
    await ref
        .read(planRepoProvider)
        .addItems(
          widget.dayId,
          picked,
          cycle: ref.read(activeCycleProvider)?.type,
        );
  }

  Future<void> _editItem(PlanItemDetail i) async {
    final repo = ref.read(planRepoProvider);
    final targets = await showTargetsSheet(
      context,
      exercise: i.exercise,
      initial: i.targets,
      onRemove: () => repo.deleteItem(i.item.id),
    );
    if (targets != null) await repo.updateItem(i.item.id, targets);
  }

  Future<void> _editDay(
    PlanSchedule schedule,
    PlanDayDetail detail,
    List<PlanDayDetail> all,
  ) async {
    final input = await showDaySheet(
      context,
      schedule: schedule,
      name: detail.day.name,
      weekday: detail.day.weekday,
      taken: {for (final d in all) ?d.day.weekday},
      editing: true,
    );
    if (input == null) return;
    await ref
        .read(planRepoProvider)
        .updateDay(detail.day.id, name: input.name, weekday: input.weekday);
  }

  Future<void> _deleteDay(PlanDayDetail detail) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete ${detail.day.name}?',
      message: 'Its exercises and targets are removed from the plan.',
    );
    if (!ok) return;
    await ref.read(planRepoProvider).deleteDay(detail.day.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final plan = ref.watch(planProvider(widget.planId)).value;
    final all = ref.watch(planDaysProvider(widget.planId)).value;
    final detail = all?.where((d) => d.day.id == widget.dayId).firstOrNull;
    if (plan == null || all == null || detail == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }

    var items = detail.items;
    final order = _order;
    if (order != null) {
      final byId = {for (final i in items) i.item.id: i};
      if (order.length == items.length && order.every(byId.containsKey)) {
        items = [for (final id in order) byId[id]!];
      }
    }
    final weekday = detail.day.weekday;

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plan.schedule == PlanSchedule.weekly && weekday != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'Every ${weekdayNames[weekday - 1]}',
              style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
            ),
          ),
        if (items.isNotEmpty) ...[
          FadeSlideIn(
            child: Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.fitness_center_rounded,
                    value: '${items.length}',
                    label: 'Exercises',
                    color: accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    icon: Icons.stacked_bar_chart_rounded,
                    value: '${detail.totalSets}',
                    label: 'Sets',
                    color: CycleType.bulk.color,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    icon: Icons.timer_outlined,
                    value: '~${detail.estimatedMinutes}m',
                    label: 'Estimated',
                    color: CycleType.endurance.color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FadeSlideIn(
            delay: const Duration(milliseconds: 60),
            child: SurfaceCard(
              padding: const EdgeInsets.all(16),
              child: MuscleBalanceBar(exercises: detail.exercises),
            ),
          ),
          const SizedBox(height: 22),
          SectionHeader(
            'Exercises',
            trailing: Text(
              'Tap to set targets · hold to reorder',
              style: t.labelSmall!.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: EmptyState(
              icon: Icons.playlist_add_rounded,
              title: 'Add exercises',
              message:
                  'Pick from the library. Sets, reps and rest are suggested '
                  'from your current cycle, and you can change them.',
              action: FilledButton.icon(
                onPressed: () => _addExercises(detail),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add exercises'),
              ),
            ),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(detail.day.name),
        actions: [
          IconButton(
            tooltip: 'Edit day',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _editDay(plan.schedule, detail, all),
          ),
          IconButton(
            tooltip: 'Delete day',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _deleteDay(detail),
          ),
        ],
      ),
      floatingActionButton: items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addExercises(detail),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add exercises'),
            ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        header: header,
        buildDefaultDragHandles: false,
        itemCount: items.length,
        onReorderItem: (from, to) {
          final ids = [for (final i in items) i.item.id];
          final id = ids.removeAt(from);
          ids.insert(to, id);
          setState(() => _order = ids);
          ref.read(planRepoProvider).reorderItems(ids);
        },
        proxyDecorator: (child, _, _) => Material(
          color: Colors.transparent,
          elevation: 8,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(Radii.tile),
          child: child,
        ),
        itemBuilder: (context, i) {
          final item = items[i];
          return Padding(
            key: ValueKey(item.item.id),
            padding: const EdgeInsets.only(bottom: 10),
            child: ReorderableDelayedDragStartListener(
              index: i,
              child: _ItemTile(
                item: item,
                index: i,
                onTap: () => _editItem(item),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.index,
    required this.onTap,
  });

  final PlanItemDetail item;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = item.exercise;
    final targets = item.targets;
    return Pressable(
      onTap: onTap,
      borderRadius: Radii.tile,
      child: Ink(
        padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          children: [
            MuscleIcon(muscle: e.muscle),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.name,
                    style: t.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Pill(
                        icon: e.tracking.icon,
                        text: describeTargets(
                          e.tracking,
                          sets: targets.sets,
                          reps: targets.reps,
                          weightKg: targets.weightKg,
                          durationSec: targets.durationSec,
                          distanceKm: targets.distanceKm,
                        ),
                        color: e.muscle.color,
                      ),
                      if (targets.restSec != null)
                        _Pill(
                          icon: Icons.hourglass_bottom_rounded,
                          text: restLabel(targets.restSec!),
                          color: AppColors.textSecondary,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            // Set dots: one per planned set.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                children: [
                  for (var r = 0; r < (targets.sets / 4).ceil(); r++)
                    Row(
                      children: [
                        for (
                          var c = r * 4;
                          c < targets.sets && c < r * 4 + 4;
                          c++
                        )
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.all(1.5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: e.muscle.color.withValues(alpha: 0.8),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium!
                .copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
