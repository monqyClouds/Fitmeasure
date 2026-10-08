import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';

/// Creates or edits a custom exercise belonging to the current profile.
class ExerciseEditorScreen extends ConsumerStatefulWidget {
  const ExerciseEditorScreen({super.key, this.exercise, this.initialName});
  final Exercise? exercise;
  final String? initialName;

  @override
  ConsumerState<ExerciseEditorScreen> createState() =>
      _ExerciseEditorScreenState();
}

class _ExerciseEditorScreenState extends ConsumerState<ExerciseEditorScreen> {
  late final _name = TextEditingController(
    text: widget.exercise?.name ?? widget.initialName ?? '',
  );
  late final _notes = TextEditingController(text: widget.exercise?.notes ?? '');
  late MuscleGroup _muscle = widget.exercise?.muscle ?? MuscleGroup.chest;
  late Equipment _equipment = widget.exercise?.equipment ?? Equipment.barbell;
  late TrackingType _tracking = widget.exercise?.tracking ?? TrackingType.reps;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    await ref
        .read(exerciseRepoProvider)
        .saveCustom(
          id: widget.exercise?.id,
          profileId: ref.read(currentProfileIdProvider)!,
          name: _name.text,
          muscle: _muscle,
          equipment: _equipment,
          tracking: _tracking,
          notes: _notes.text,
        );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      title: 'Delete ${widget.exercise!.name}?',
      message: 'Its media and any logged sets for it will be removed.',
    );
    if (!ok) return;
    await ref.read(exerciseRepoProvider).deleteCustom(widget.exercise!.id);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.exercise != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit exercise' : 'New exercise'),
        actions: [
          if (editing)
            IconButton(
              tooltip: 'Delete',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _name,
            autofocus: !editing,
            maxLength: 60,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          const SectionHeader('Muscle group'),
          _ChoiceWrap<MuscleGroup>(
            values: MuscleGroup.values,
            selected: _muscle,
            label: (m) => m.label,
            color: (m) => m.color,
            onSelected: (m) => setState(() => _muscle = m),
          ),
          const SizedBox(height: 24),
          const SectionHeader('Equipment'),
          _ChoiceWrap<Equipment>(
            values: Equipment.values,
            selected: _equipment,
            label: (e) => e.label,
            onSelected: (e) => setState(() => _equipment = e),
          ),
          const SizedBox(height: 24),
          const SectionHeader('What to log per set'),
          for (final tt in TrackingType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TrackingOption(
                type: tt,
                selected: tt == _tracking,
                onTap: () => setState(() => _tracking = tt),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes / cues'),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : _save,
            child: Text(editing ? 'Save changes' : 'Add exercise'),
          ),
        ],
      ),
    );
  }
}

class _ChoiceWrap<T> extends StatelessWidget {
  const _ChoiceWrap({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.color,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final Color Function(T)? color;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            selectedColor: (color?.call(v) ?? accent).withValues(alpha: 0.2),
            onSelected: (_) => onSelected(v),
          ),
      ],
    );
  }
}

class _TrackingOption extends StatelessWidget {
  const _TrackingOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final TrackingType type;
  final bool selected;
  final VoidCallback onTap;

  String get _description => switch (type) {
    TrackingType.reps => 'Reps and weight (kg) for each set',
    TrackingType.time => 'Duration of each set, e.g. a plank',
    TrackingType.distance => 'Distance (km) and time, e.g. a run',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.standard,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(
                  accent.withValues(alpha: 0.10),
                  AppColors.surface,
                )
              : AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.6)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(type.icon, color: selected ? accent : AppColors.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(type.label, style: t.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    _description,
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
