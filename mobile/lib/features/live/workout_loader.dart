import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/targets.dart';
import '../../domain/units.dart';
import '../library/exercise_picker_screen.dart';
import '../library/muscle_icon.dart';
import '../plans/targets_sheet.dart';
import 'room_client.dart';
import 'workout_steps.dart';

/// For the host: pick a workout to run for the room, one of your plan days
/// or one built now.
Future<void> showWorkoutLoader(BuildContext context, RoomClient client) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scroll) =>
            _LoaderSheet(client: client, scroll: scroll),
      ),
    );

class _LoaderSheet extends ConsumerWidget {
  const _LoaderSheet({required this.client, required this.scroll});
  final RoomClient client;
  final ScrollController scroll;

  void _load(
    BuildContext context,
    String title,
    List<(Exercise, Targets)> items,
  ) {
    client.loadWorkout(title, workoutSteps(items));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final plans = ref.watch(plansProvider).value ?? const [];
    final days = [
      for (final p in plans)
        for (final d in p.days)
          if (d.items.isNotEmpty) (p.plan.name, d),
    ];
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text('Run a workout', style: t.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Everyone sees the same timer: each set, rest and break. You can '
          'pause, skip and add water breaks as you go.',
          style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: () async {
            final navigator = Navigator.of(context);
            final built =
                await Navigator.push<(String, List<(Exercise, Targets)>)>(
                  context,
                  MaterialPageRoute(builder: (_) => const BuildWorkoutScreen()),
                );
            if (built != null && navigator.mounted) {
              client.loadWorkout(built.$1, workoutSteps(built.$2));
              navigator.pop();
            }
          },
          icon: const Icon(Icons.edit_note_rounded),
          label: const Text('Build one now'),
        ),
        if (days.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'FROM YOUR PLANS',
            style: t.labelSmall!.copyWith(
              color: AppColors.textTertiary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          for (final (plan, d) in days)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(Radii.tile),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.tile),
                  ),
                  leading: SizedBox(
                    width: 44,
                    child: Stack(
                      children: [
                        for (final (i, e) in d.exercises.take(3).indexed)
                          Positioned(
                            left: i * 8.0,
                            top: i * 4.0,
                            child: MuscleIcon(muscle: e.muscle, size: 28),
                          ),
                      ],
                    ),
                  ),
                  title: Text(d.day.name),
                  subtitle: Text(
                    '$plan · ${d.items.length} exercises · '
                    '${d.totalSets} sets · ~${d.estimatedMinutes} min',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.play_circle_outline_rounded),
                  onTap: () => _load(context, d.day.name, [
                    for (final i in d.items) (i.exercise, i.targets),
                  ]),
                ),
              ),
            ),
        ] else ...[
          const SizedBox(height: 20),
          Text(
            'Plan days you create show here, ready to run.',
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ],
    );
  }
}

/// Builds a workout on the spot: pick exercises, set each one's sets,
/// time or reps, and rest. Returns its title and exercises.
class BuildWorkoutScreen extends ConsumerStatefulWidget {
  const BuildWorkoutScreen({super.key});

  @override
  ConsumerState<BuildWorkoutScreen> createState() => _BuildWorkoutScreenState();
}

class _BuildWorkoutScreenState extends ConsumerState<BuildWorkoutScreen> {
  final _title = TextEditingController(text: 'Workout');
  final _items = <(Exercise, Targets)>[];

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final picked = await pickExercises(
      context,
      exclude: {for (final (e, _) in _items) e.id},
    );
    if (picked == null) return;
    final cycle = ref.read(activeCycleProvider)?.type;
    setState(() {
      for (final e in picked) {
        _items.add((e, defaultTargets(e.tracking, cycle)));
      }
    });
  }

  Future<void> _edit(int i) async {
    final (e, t) = _items[i];
    final updated = await showTargetsSheet(
      context,
      exercise: e,
      initial: t,
      onRemove: () {
        setState(() => _items.removeAt(i));
        Navigator.pop(context);
      },
    );
    if (updated != null) setState(() => _items[i] = (e, updated));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final steps = workoutSteps(_items);
    final minutes = (timedSeconds(steps) / 60).ceil();
    return Scaffold(
      appBar: AppBar(title: const Text('Build a workout')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => setState(() {
              final item = _items.removeAt(from);
              _items.insert(to, item);
            }),
            children: [
              for (final (i, (e, tg)) in _items.indexed)
                Padding(
                  key: ValueKey(e.id),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(Radii.tile),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.tile),
                      ),
                      leading: MuscleIcon(muscle: e.muscle, size: 36),
                      title: Text(e.name),
                      subtitle: Text(
                        [
                          describeTargets(
                            e.tracking,
                            sets: tg.sets,
                            reps: tg.reps,
                            weightKg: tg.weightKg,
                            durationSec: tg.durationSec,
                            distanceKm: tg.distanceKm,
                          ),
                          if ((tg.restSec ?? 0) > 0)
                            'rest ${restLabel(tg.restSec!)}',
                        ].join(' · '),
                      ),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_handle_rounded),
                      ),
                      onTap: () => _edit(i),
                    ),
                  ),
                ),
            ],
          ),
          OutlinedButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add exercises'),
          ),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Tap an exercise to set its sets, time or reps, and rest. '
              '${steps.length} steps'
              '${minutes > 0 ? ', $minutes min of timed work and rest' : ''}.',
              style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ],
      ),
      floatingActionButton: _items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context, (
                _title.text.trim().isEmpty ? 'Workout' : _title.text.trim(),
                List.of(_items),
              )),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Load into room'),
            ),
    );
  }
}
