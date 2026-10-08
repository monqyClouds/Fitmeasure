import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/measurement_repo.dart';
import '../../domain/dates.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/visuals.dart';
import 'measurement_style.dart';

/// Chart ranges, in days; null is everything.
const chartRanges = <(String, int?)>[
  ('1M', 30),
  ('3M', 91),
  ('6M', 182),
  ('1Y', 365),
  ('All', null),
];

/// One measurement over time, shaded by cycle, with its full history.
class MeasurementDetailScreen extends ConsumerStatefulWidget {
  const MeasurementDetailScreen({super.key, required this.typeId});
  final int typeId;

  @override
  ConsumerState<MeasurementDetailScreen> createState() =>
      _MeasurementDetailScreenState();
}

class _MeasurementDetailScreenState
    extends ConsumerState<MeasurementDetailScreen> {
  int? _rangeDays = 91;

  Future<void> _log(MeasurementSeries s) async {
    final profileId = ref.read(currentProfileIdProvider);
    final result = await showValueSheet(
      context,
      type: s.type,
      hint: s.latest?.value,
    );
    if (result == null || profileId == null) return;
    final (value, at) = result;
    await ref.read(measurementRepoProvider).logMany(profileId, {
      s.type.id: value,
    }, at: at);
  }

  Future<void> _editEntry(MeasurementSeries s, Measurement m) async {
    final repo = ref.read(measurementRepoProvider);
    final result = await showValueSheet(
      context,
      type: s.type,
      initial: m,
      onDelete: () => repo.delete(m.id),
    );
    if (result == null) return;
    final (value, at) = result;
    await repo.update(m.id, value: value, at: at);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = ref.watch(measurementSeriesProvider(widget.typeId)).value;
    final cycles = ref.watch(cyclesProvider).value ?? const <Cycle>[];
    if (s == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }
    final style = measurementStyle(s.type);
    final unit = s.type.unit;
    final now = DateTime.now();
    final from = _rangeDays == null
        ? null
        : dateOnly(now).subtract(Duration(days: _rangeDays!));
    final shown = [
      for (final e in s.entries)
        if (from == null || !e.recordedAt.isBefore(from)) e,
    ];
    final latest = s.latest;
    final values = [for (final e in s.entries) e.value];

    return Scaffold(
      appBar: AppBar(title: Text(s.type.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _log(s),
        backgroundColor: style.color,
        foregroundColor: onColor(style.color),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Log'),
      ),
      body: GlowBackdrop(
        color: style.color,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
          children: [
            FadeSlideIn(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          latest == null
                              ? 'No entries yet'
                              : formatMeasurement(latest.value, unit),
                          style: t.displaySmall,
                        ),
                        if (latest != null)
                          Text(
                            'on ${formatDate(latest.recordedAt)}',
                            style: t.bodyMedium!.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ChangePill(
                        change: s.changeOver(30, now),
                        unit: unit,
                        suffix: 'in 30 days',
                        color: style.color,
                      ),
                      const SizedBox(height: 6),
                      ChangePill(
                        change: s.totalChange,
                        unit: unit,
                        suffix: 'overall',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              child: SurfaceCard(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: RangeSelector(
                        value: _rangeDays,
                        color: style.color,
                        onChanged: (d) => setState(() => _rangeDays = d),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TrendChart(
                      points: [for (final e in shown) (e.recordedAt, e.value)],
                      color: style.color,
                      cycles: cycles,
                      unit: unit,
                      height: 220,
                    ),
                    if (shown.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: CycleLegend(
                          cycles: cycles,
                          from: shown.first.recordedAt,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (values.isNotEmpty) ...[
              const SizedBox(height: 14),
              FadeSlideIn(
                delay: const Duration(milliseconds: 120),
                child: Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        icon: Icons.south_rounded,
                        value: formatMeasurement(
                          values.reduce((a, b) => a < b ? a : b),
                          unit,
                        ),
                        label: 'Lowest',
                        color: style.color,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        icon: Icons.north_rounded,
                        value: formatMeasurement(
                          values.reduce((a, b) => a > b ? a : b),
                          unit,
                        ),
                        label: 'Highest',
                        color: style.color,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: StatTile(
                        icon: Icons.format_list_numbered_rounded,
                        value: '${values.length}',
                        label: 'Entries',
                        color: style.color,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const SectionHeader('History'),
              for (final (i, e) in s.entries.reversed.indexed)
                _EntryTile(
                  entry: e,
                  previous: i + 1 < s.entries.length
                      ? s.entries[s.entries.length - i - 2]
                      : null,
                  unit: unit,
                  color: style.color,
                  onTap: () => _editEntry(s, e),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 1M / 3M / 6M / 1Y / All.
class RangeSelector extends StatelessWidget {
  const RangeSelector({
    super.key,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final int? value;
  final Color color;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        for (final (label, days) in chartRanges)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => onChanged(days),
              child: AnimatedContainer(
                duration: Motion.fast,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: value == days
                      ? color.withValues(alpha: 0.2)
                      : AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  label,
                  style: t.labelMedium!.copyWith(
                    color: value == days ? color : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.previous,
    required this.unit,
    required this.color,
    required this.onTap,
  });

  final Measurement entry;
  final Measurement? previous;
  final String unit;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final change = previous == null ? null : entry.value - previous!.value;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.chip),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                DateFormat('EEE d MMM yyyy').format(entry.recordedAt),
                style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
              ),
            ),
            if (change != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  formatChange(change, unit) ?? '',
                  style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
                ),
              ),
            Text(formatMeasurement(entry.value, unit), style: t.titleSmall),
          ],
        ),
      ),
    );
  }
}
