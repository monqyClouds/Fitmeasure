import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';

typedef DayInput = ({String name, int? weekday});

/// Asks for a plan day's name, and its weekday on weekly plans. Weekdays in
/// [taken] already have a day and can't be picked.
Future<DayInput?> showDaySheet(
  BuildContext context, {
  required PlanSchedule schedule,
  String? name,
  int? weekday,
  Set<int> taken = const {},
  bool editing = false,
}) => showModalBottomSheet<DayInput>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _DaySheet(
    schedule: schedule,
    name: name,
    weekday: weekday,
    taken: taken,
    editing: editing,
  ),
);

class _DaySheet extends StatefulWidget {
  const _DaySheet({
    required this.schedule,
    required this.name,
    required this.weekday,
    required this.taken,
    required this.editing,
  });

  final PlanSchedule schedule;
  final String? name;
  final int? weekday;
  final Set<int> taken;
  final bool editing;

  @override
  State<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends State<_DaySheet> {
  late final _name = TextEditingController(text: widget.name ?? '');
  late int? _weekday =
      widget.weekday ??
      (widget.schedule == PlanSchedule.weekly
          ? [
              for (var d = 1; d <= 7; d++)
                if (!widget.taken.contains(d)) d,
            ].firstOrNull
          : null);

  bool get _weekly => widget.schedule == PlanSchedule.weekly;
  bool get _valid =>
      _name.text.trim().isNotEmpty && (!_weekly || _weekday != null);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!_valid) return;
    Navigator.pop<DayInput>(context, (
      name: _name.text.trim(),
      weekday: _weekly ? _weekday : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.editing ? 'Edit day' : 'New training day',
            style: t.headlineSmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            autofocus: !widget.editing,
            textCapitalization: TextCapitalization.words,
            maxLength: 30,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Push, Legs, Upper A',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          if (_weekly) ...[
            const SizedBox(height: 20),
            Text('Day of the week', style: t.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                for (var d = 1; d <= 7; d++) ...[
                  if (d > 1) const SizedBox(width: 6),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final taken =
                            widget.taken.contains(d) && d != widget.weekday;
                        final selected = _weekday == d;
                        return GestureDetector(
                          onTap: taken
                              ? null
                              : () => setState(() => _weekday = d),
                          child: AnimatedContainer(
                            duration: Motion.fast,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: selected ? accent : AppColors.surfaceHigh,
                            ),
                            child: Text(
                              weekdayShort[d - 1].substring(0, 2),
                              style: t.labelMedium!.copyWith(
                                color: selected
                                    ? onColor(accent)
                                    : taken
                                    ? AppColors.surfaceHighest
                                    : AppColors.textSecondary,
                                decoration: taken
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _valid ? _save : null,
              child: Text(widget.editing ? 'Save' : 'Add day'),
            ),
          ),
        ],
      ),
    );
  }
}
