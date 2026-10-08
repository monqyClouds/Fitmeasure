import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../domain/targets.dart';
import '../../domain/units.dart';
import '../library/muscle_icon.dart';

const restChoices = [0, 30, 45, 60, 90, 120, 180, 240];

String restLabel(int sec) => sec == 0
    ? 'None'
    : sec < 60 || sec % 60 != 0
    ? '${sec}s'
    : '${sec ~/ 60} min';

/// Edits the targets for [exercise]. Returns the new targets, or null when
/// dismissed. [onRemove], when given, adds a remove button.
Future<Targets?> showTargetsSheet(
  BuildContext context, {
  required Exercise exercise,
  required Targets initial,
  VoidCallback? onRemove,
}) => showModalBottomSheet<Targets>(
  context: context,
  isScrollControlled: true,
  builder: (_) =>
      _TargetsSheet(exercise: exercise, initial: initial, onRemove: onRemove),
);

class _TargetsSheet extends StatefulWidget {
  const _TargetsSheet({
    required this.exercise,
    required this.initial,
    this.onRemove,
  });

  final Exercise exercise;
  final Targets initial;
  final VoidCallback? onRemove;

  @override
  State<_TargetsSheet> createState() => _TargetsSheetState();
}

class _TargetsSheetState extends State<_TargetsSheet> {
  late int _sets = widget.initial.sets;
  late int _rest = widget.initial.restSec ?? 0;
  late final _reps = TextEditingController(
    text: widget.initial.reps?.toString() ?? '',
  );
  late final _weight = TextEditingController(
    text: widget.initial.weightKg == null
        ? ''
        : formatNumber(widget.initial.weightKg!),
  );
  late final _duration = TextEditingController(
    text: widget.initial.durationSec == null
        ? ''
        : formatDuration(widget.initial.durationSec!),
  );
  late final _distance = TextEditingController(
    text: widget.initial.distanceKm == null
        ? ''
        : formatNumber(widget.initial.distanceKm!),
  );

  @override
  void dispose() {
    _reps.dispose();
    _weight.dispose();
    _duration.dispose();
    _distance.dispose();
    super.dispose();
  }

  void _save() {
    final tracking = widget.exercise.tracking;
    Navigator.pop<Targets>(context, (
      sets: _sets,
      reps: tracking == TrackingType.reps ? int.tryParse(_reps.text) : null,
      weightKg: tracking == TrackingType.reps
          ? parseDecimal(_weight.text)
          : null,
      durationSec: tracking == TrackingType.reps
          ? null
          : parseDuration(_duration.text),
      distanceKm: tracking == TrackingType.distance
          ? parseDecimal(_distance.text)
          : null,
      restSec: _rest == 0 ? null : _rest,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = widget.exercise;
    final fields = switch (e.tracking) {
      TrackingType.reps => [
        Expanded(child: intField(_reps, 'Reps')),
        const SizedBox(width: 12),
        Expanded(child: decimalField(_weight, 'Weight', 'kg')),
      ],
      TrackingType.time => [
        Expanded(child: durationField(_duration, 'Time per set')),
      ],
      TrackingType.distance => [
        Expanded(child: decimalField(_distance, 'Distance', 'km')),
        const SizedBox(width: 12),
        Expanded(child: durationField(_duration, 'Time')),
      ],
    };

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MuscleIcon(muscle: e.muscle),
                const SizedBox(width: 14),
                Expanded(child: Text(e.name, style: t.headlineSmall)),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: Text('Sets', style: t.titleMedium)),
                Stepper(
                  value: _sets,
                  min: 1,
                  max: 20,
                  onChanged: (v) => setState(() => _sets = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(children: fields),
            const SizedBox(height: 20),
            Text('Rest between sets', style: t.titleSmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in restChoices)
                  ChoiceChip(
                    label: Text(restLabel(r)),
                    selected: _rest == r,
                    onSelected: (_) => setState(() => _rest = r),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
            if (widget.onRemove != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onRemove!();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  child: const Text('Remove exercise'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Widget intField(TextEditingController c, String label, {String? hint}) =>
    TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );

Widget decimalField(
  TextEditingController c,
  String label,
  String suffix, {
  String? hint,
}) => TextField(
  controller: c,
  keyboardType: const TextInputType.numberWithOptions(decimal: true),
  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
  textAlign: TextAlign.center,
  decoration: InputDecoration(
    labelText: label,
    suffixText: suffix,
    hintText: hint,
  ),
);

Widget durationField(TextEditingController c, String label, {String? hint}) =>
    TextField(
      controller: c,
      keyboardType: TextInputType.datetime,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9:]'))],
      textAlign: TextAlign.center,
      decoration: InputDecoration(labelText: label, hintText: hint ?? 'm:ss'),
    );

/// A compact "−  n  +" control.
class Stepper extends StatelessWidget {
  const Stepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 99,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Fewer',
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: t.titleLarge,
            ),
          ),
          IconButton(
            tooltip: 'More',
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}
