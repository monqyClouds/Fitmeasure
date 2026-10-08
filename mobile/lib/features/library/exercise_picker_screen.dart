import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import 'exercise_editor_screen.dart';
import 'muscle_icon.dart';

/// Lets the user tick several exercises from the library. Returns them in
/// the order they were ticked, or null if cancelled.
Future<List<Exercise>?> pickExercises(
  BuildContext context, {
  Set<int> exclude = const {},
}) => Navigator.push<List<Exercise>>(
  context,
  MaterialPageRoute(builder: (_) => ExercisePickerScreen(exclude: exclude)),
);

class ExercisePickerScreen extends ConsumerStatefulWidget {
  const ExercisePickerScreen({super.key, this.exclude = const {}});

  /// Exercises already added, shown as such and not selectable.
  final Set<int> exclude;

  @override
  ConsumerState<ExercisePickerScreen> createState() =>
      _ExercisePickerScreenState();
}

class _ExercisePickerScreenState extends ConsumerState<ExercisePickerScreen> {
  final _search = TextEditingController();
  final _selected = <Exercise>[];
  MuscleGroup? _muscle;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(Exercise e) => setState(() {
    if (_selected.any((s) => s.id == e.id)) {
      _selected.removeWhere((s) => s.id == e.id);
    } else {
      _selected.add(e);
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final q = _search.text.trim().toLowerCase();
    final all = ref.watch(libraryProvider).value ?? const [];
    final items = [
      for (final e in all)
        if ((_muscle == null || e.exercise.muscle == _muscle) &&
            (q.isEmpty || e.exercise.name.toLowerCase().contains(q)))
          e.exercise,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add exercises'),
        actions: [
          IconButton(
            tooltip: 'New custom exercise',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ExerciseEditorScreen(initialName: _search.text.trim()),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedSize(
        duration: Motion.medium,
        curve: Motion.standard,
        child: _selected.isEmpty
            ? const SizedBox(width: double.infinity)
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: Text(
                      _selected.length == 1
                          ? 'Add 1 exercise'
                          : 'Add ${_selected.length} exercises',
                    ),
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search exercises',
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.textTertiary,
                ),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _search.clear()),
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              children: [
                for (final m in MuscleGroup.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(m.label),
                      selected: _muscle == m,
                      selectedColor: m.color.withValues(alpha: 0.2),
                      onSelected: (_) =>
                          setState(() => _muscle = _muscle == m ? null : m),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Nothing found',
                    message:
                        'Try another search, or add it as your own exercise '
                        'with the + button.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final e = items[i];
                      final added = widget.exclude.contains(e.id);
                      final order = _selected.indexWhere((s) => s.id == e.id);
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Radii.tile),
                        ),
                        enabled: !added,
                        onTap: () => _toggle(e),
                        leading: MuscleIcon(muscle: e.muscle, size: 40),
                        title: Text(e.name, style: t.titleSmall),
                        subtitle: Text(
                          added
                              ? 'Already added'
                              : '${e.muscle.label} · ${e.equipment.label}',
                          style: t.bodySmall!.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        trailing: AnimatedSwitcher(
                          duration: Motion.fast,
                          child: order >= 0
                              ? CircleAvatar(
                                  key: ValueKey(order),
                                  radius: 13,
                                  backgroundColor: accent,
                                  child: Text(
                                    '${order + 1}',
                                    style: t.labelMedium!.copyWith(
                                      color: onColor(accent),
                                    ),
                                  ),
                                )
                              : Icon(
                                  added
                                      ? Icons.check_rounded
                                      : Icons.circle_outlined,
                                  key: const ValueKey(-1),
                                  color: AppColors.surfaceHighest,
                                ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
