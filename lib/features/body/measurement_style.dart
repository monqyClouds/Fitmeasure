import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/dates.dart';
import '../../domain/units.dart';

/// An icon and colour for a measurement type, from its name and unit.
({IconData icon, Color color}) measurementStyle(MeasurementType type) {
  final n = type.name.toLowerCase();
  if (n.contains('weight')) {
    return (
      icon: Icons.monitor_weight_outlined,
      color: const Color(0xFF5AA9FF),
    );
  }
  if (type.unit == '%' || n.contains('fat')) {
    return (icon: Icons.water_drop_outlined, color: const Color(0xFFFFB547));
  }
  if (n.contains('waist') || n.contains('hip')) {
    return (icon: Icons.straighten_rounded, color: const Color(0xFFFF6B9A));
  }
  if (n.contains('arm') || n.contains('shoulder') || n.contains('chest')) {
    return (icon: Icons.fitness_center_rounded, color: const Color(0xFFFF7A59));
  }
  if (n.contains('thigh') || n.contains('calf') || n.contains('calves')) {
    return (
      icon: Icons.directions_walk_rounded,
      color: const Color(0xFFA99BFF),
    );
  }
  return (icon: Icons.straighten_rounded, color: const Color(0xFF3DD6C6));
}

String formatMeasurement(double v, String unit) =>
    unit.isEmpty ? formatNumber(v) : '${formatNumber(v)} $unit';

/// "▲ 1.2 kg" style change, or null when there's nothing to compare.
String? formatChange(double? change, String unit) {
  if (change == null) return null;
  final rounded = double.parse(change.toStringAsFixed(2));
  if (rounded == 0) return 'No change';
  final sign = rounded > 0 ? '+' : '−';
  return '$sign${formatMeasurement(rounded.abs(), unit)}';
}

/// A small pill showing a change with an arrow.
class ChangePill extends StatelessWidget {
  const ChangePill({
    super.key,
    required this.change,
    required this.unit,
    this.suffix,
    this.color,
  });

  final double? change;
  final String unit;
  final String? suffix;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = formatChange(change, unit);
    if (text == null) return const SizedBox.shrink();
    final c = color ?? AppColors.textSecondary;
    final up = (change ?? 0) > 0.004;
    final down = (change ?? 0) < -0.004;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up
                ? Icons.north_east_rounded
                : down
                ? Icons.south_east_rounded
                : Icons.east_rounded,
            size: 13,
            color: c,
          ),
          const SizedBox(width: 4),
          Text(
            suffix == null ? text : '$text $suffix',
            style: Theme.of(context).textTheme.labelMedium!.copyWith(color: c),
          ),
        ],
      ),
    );
  }
}

/// Asks for one value of [type] and when it was taken. Returns null when
/// dismissed. With [initial] it edits an entry and offers [onDelete].
Future<(double, DateTime)?> showValueSheet(
  BuildContext context, {
  required MeasurementType type,
  Measurement? initial,
  double? hint,
  VoidCallback? onDelete,
}) => showModalBottomSheet<(double, DateTime)>(
  context: context,
  isScrollControlled: true,
  builder: (_) =>
      _ValueSheet(type: type, initial: initial, hint: hint, onDelete: onDelete),
);

class _ValueSheet extends StatefulWidget {
  const _ValueSheet({
    required this.type,
    this.initial,
    this.hint,
    this.onDelete,
  });

  final MeasurementType type;
  final Measurement? initial;
  final double? hint;
  final VoidCallback? onDelete;

  @override
  State<_ValueSheet> createState() => _ValueSheetState();
}

class _ValueSheetState extends State<_ValueSheet> {
  late final _value = TextEditingController(
    text: widget.initial == null ? '' : formatNumber(widget.initial!.value),
  );
  late DateTime _at = widget.initial?.recordedAt ?? DateTime.now();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(
      () => _at = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _at.hour,
        _at.minute,
      ),
    );
  }

  void _save() {
    final v = parseDecimal(_value.text);
    if (v == null) return;
    Navigator.pop(context, (v, _at));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final style = measurementStyle(widget.type);
    final today = dateOnly(_at) == dateOnly(DateTime.now());
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: style.color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(style.icon, color: style.color),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(widget.type.name, style: t.headlineSmall)),
            ],
          ),
          const SizedBox(height: 22),
          TextField(
            controller: _value,
            autofocus: true,
            textAlign: TextAlign.center,
            style: t.displaySmall,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: InputDecoration(
              hintText: widget.hint == null ? '0' : formatNumber(widget.hint!),
              suffixText: widget.type.unit,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Center(
            child: ActionChip(
              avatar: const Icon(Icons.event_rounded, size: 18),
              label: Text(
                today ? 'Today' : DateFormat('EEE d MMM yyyy').format(_at),
              ),
              onPressed: _pickDate,
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: parseDecimal(_value.text) == null ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: style.color,
              foregroundColor: onColor(style.color),
            ),
            child: Text(widget.initial == null ? 'Save' : 'Save changes'),
          ),
          if (widget.onDelete != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onDelete!();
              },
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('Delete entry'),
            ),
          ],
        ],
      ),
    );
  }
}
