import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/cycle_repo.dart';
import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';

class CycleEditorScreen extends ConsumerStatefulWidget {
  const CycleEditorScreen({super.key, this.cycle});
  final Cycle? cycle;

  @override
  ConsumerState<CycleEditorScreen> createState() => _CycleEditorScreenState();
}

class _CycleEditorScreenState extends ConsumerState<CycleEditorScreen> {
  late CycleType _type = widget.cycle?.type ?? CycleType.bulk;
  late final _name = TextEditingController(text: widget.cycle?.name ?? '');
  late final _goal = TextEditingController(
    text: widget.cycle?.goalWeightKg?.toStringAsFixed(1) ?? '',
  );
  late final _notes = TextEditingController(text: widget.cycle?.notes ?? '');
  late DateTime _start = widget.cycle?.startDate ?? dateOnly(DateTime.now());
  late DateTime? _end =
      widget.cycle?.endDate ??
      (widget.cycle == null ? _defaultEnd(_type, _start) : null);

  static DateTime? _defaultEnd(CycleType type, DateTime start) {
    final w = type.defaultWeeks;
    return w == null ? null : start.add(Duration(days: w * 7 - 1));
  }

  int? get _weeks =>
      _end == null ? null : (_end!.difference(_start).inDays + 1 + 6) ~/ 7;

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _selectType(CycleType type) {
    setState(() {
      _type = type;
      if (widget.cycle == null) _end = _defaultEnd(type, _start);
    });
  }

  void _setWeeks(int? weeks) => setState(() {
    _end = weeks == null ? null : _start.add(Duration(days: weeks * 7 - 1));
  });

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked == null) return;
    setState(() {
      final weeks = _weeks;
      _start = picked;
      if (weeks != null) _end = picked.add(Duration(days: weeks * 7 - 1));
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _end ?? _start.add(const Duration(days: 55)),
      firstDate: _start,
      lastDate: _start.add(const Duration(days: 365 * 3)),
    );
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final profileId = ref.read(currentProfileIdProvider)!;
    final name = _name.text.trim().isEmpty
        ? '${_type.label} ${formatShortDate(_start)}'
        : _name.text.trim();
    try {
      await ref
          .read(cycleRepoProvider)
          .save(
            id: widget.cycle?.id,
            profileId: profileId,
            type: _type,
            name: name,
            startDate: _start,
            endDate: _end,
            goalWeightKg: double.tryParse(_goal.text.replaceAll(',', '.')),
            notes: _notes.text,
          );
    } on CycleOverlapException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      title: 'Delete cycle?',
      message: 'Workouts logged during it are kept, but lose their link to it.',
    );
    if (!ok) return;
    await ref.read(cycleRepoProvider).delete(widget.cycle!.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _endToday() async {
    await ref.read(cycleRepoProvider).endToday(widget.cycle!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final editing = widget.cycle != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit cycle' : 'New cycle'),
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
          const SectionHeader('Goal'),
          for (final (i, type) in CycleType.values.indexed)
            FadeSlideIn.staggered(
              index: i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _TypeOption(
                  type: type,
                  selected: type == _type,
                  onTap: () => _selectType(type),
                ),
              ),
            ),
          const SizedBox(height: 20),
          const SectionHeader('Details'),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: '${_type.label} ${formatShortDate(_start)}',
              labelText: 'Name',
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Starts',
                  value: formatDate(_start),
                  onTap: _pickStart,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: 'Ends',
                  value: _end == null ? 'Ongoing' : formatDate(_end!),
                  onTap: _pickEnd,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in const [4, 6, 8, 12, 16])
                ChoiceChip(
                  label: Text('$w weeks'),
                  selected:
                      _end != null &&
                      _end!.difference(_start).inDays + 1 == w * 7,
                  onSelected: (_) => _setWeeks(w),
                ),
              ChoiceChip(
                label: const Text('Ongoing'),
                selected: _end == null,
                onSelected: (_) => _setWeeks(null),
              ),
            ],
          ),
          AnimatedSize(
            duration: Motion.medium,
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: _type == CycleType.bulk || _type == CycleType.cut
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: _goal,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Goal body weight',
                        suffixText: 'kg',
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes'),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _save,
            child: Text(editing ? 'Save changes' : 'Start cycle'),
          ),
          if (editing &&
              widget.cycle!.isActive &&
              (widget.cycle!.endDate == null ||
                  !isToday(widget.cycle!.endDate!))) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _endToday,
              child: const Text('End cycle today'),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Starting a new cycle ends any cycle still running the day before.',
            textAlign: TextAlign.center,
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

bool isToday(DateTime d) => dateOnly(d) == dateOnly(DateTime.now());

class _TypeOption extends StatelessWidget {
  const _TypeOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final CycleType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = type.color;
    return Pressable(
      onTap: onTap,
      borderRadius: Radii.tile,
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.standard,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(c.withValues(alpha: 0.12), AppColors.surface)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
          border: Border.all(
            color: selected ? c.withValues(alpha: 0.7) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(type.icon, color: c, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(type.label, style: t.titleMedium),
                  const SizedBox(height: 3),
                  Text(
                    type.tagline,
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${type.sets} sets · ${type.repRange} reps · ${type.restSec}s rest',
                    style: t.labelMedium!.copyWith(color: c),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: Motion.fast,
              child: selected
                  ? Icon(
                      Icons.check_circle_rounded,
                      key: const ValueKey(true),
                      color: c,
                    )
                  : const Icon(
                      Icons.circle_outlined,
                      key: ValueKey(false),
                      color: AppColors.surfaceHighest,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      borderRadius: Radii.tile,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(value, style: t.titleMedium),
          ],
        ),
      ),
    );
  }
}
