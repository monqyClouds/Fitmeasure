import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/measurement_repo.dart';
import '../../domain/dates.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import 'measurement_style.dart';
import 'measurement_types_screen.dart';

/// Enter any number of measurements taken at the same time. Empty fields
/// are skipped.
class LogMeasurementsScreen extends ConsumerStatefulWidget {
  const LogMeasurementsScreen({super.key});

  @override
  ConsumerState<LogMeasurementsScreen> createState() =>
      _LogMeasurementsScreenState();
}

class _LogMeasurementsScreenState extends ConsumerState<LogMeasurementsScreen> {
  final _fields = <int, TextEditingController>{};
  var _at = DateTime.now();
  var _saving = false;

  TextEditingController _field(int typeId) =>
      _fields[typeId] ??= TextEditingController()
        ..addListener(() => setState(() {}));

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<int, double> get _values => {
    for (final MapEntry(key: id, value: c) in _fields.entries)
      id: ?parseDecimal(c.text),
  };

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
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
  }

  Future<void> _save() async {
    final values = _values;
    final profileId = ref.read(currentProfileIdProvider);
    if (values.isEmpty || profileId == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(measurementRepoProvider).logMany(profileId, values, at: _at);
    HapticFeedback.mediumImpact();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          values.length == 1
              ? 'Saved 1 measurement'
              : 'Saved ${values.length} measurements',
        ),
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final series = ref.watch(measurementsProvider).value ?? const [];
    final count = _values.length;
    final today = dateOnly(_at) == dateOnly(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Log measurements'),
        actions: [
          IconButton(
            tooltip: 'Edit measurement types',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MeasurementTypesScreen()),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            onPressed: count == 0 || _saving ? null : _save,
            child: Text(
              count == 0
                  ? 'Enter at least one value'
                  : count == 1
                  ? 'Save 1 measurement'
                  : 'Save $count measurements',
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Row(
            children: [
              ActionChip(
                avatar: const Icon(Icons.event_rounded, size: 18),
                label: Text(
                  today ? 'Today' : DateFormat('EEE d MMM yyyy').format(_at),
                ),
                onPressed: _pickDate,
              ),
              const Spacer(),
              Text(
                'Leave blank what you skip',
                style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final (i, s) in series.indexed)
            FadeSlideIn.staggered(
              index: i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _MeasurementField(
                  series: s,
                  controller: _field(s.type.id),
                  hero: i == 0,
                ),
              ),
            ),
          if (series.isEmpty)
            const EmptyState(
              icon: Icons.straighten_rounded,
              title: 'No measurement types',
              message:
                  'Add the measurements you want to track with the '
                  'button at the top.',
            ),
        ],
      ),
    );
  }
}

class _MeasurementField extends StatelessWidget {
  const _MeasurementField({
    required this.series,
    required this.controller,
    this.hero = false,
  });

  final MeasurementSeries series;
  final TextEditingController controller;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final type = series.type;
    final style = measurementStyle(type);
    final last = series.latest;
    final filled = controller.text.isNotEmpty;
    return AnimatedContainer(
      duration: Motion.medium,
      padding: EdgeInsets.all(hero ? 16 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.tile),
        color: filled
            ? Color.alphaBlend(
                style.color.withValues(alpha: 0.1),
                AppColors.surface,
              )
            : AppColors.surface,
        border: Border.all(
          color: filled
              ? style.color.withValues(alpha: 0.5)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: hero ? 48 : 40,
            height: hero ? 48 : 40,
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(hero ? 16 : 13),
            ),
            child: Icon(style.icon, color: style.color, size: hero ? 24 : 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.name, style: hero ? t.titleLarge : t.titleSmall),
                const SizedBox(height: 2),
                Text(
                  last == null
                      ? 'No entries yet'
                      : 'Last: ${formatMeasurement(last.value, type.unit)} · '
                            '${formatDate(last.recordedAt)}',
                  style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          SizedBox(
            width: hero ? 120 : 104,
            child: TextField(
              controller: controller,
              textAlign: TextAlign.center,
              style: hero ? t.titleLarge : t.titleMedium,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                hintText: last == null ? '–' : formatNumber(last.value),
                suffixText: type.unit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
