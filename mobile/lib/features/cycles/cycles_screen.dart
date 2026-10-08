import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/cycle_repo.dart';
import '../../domain/dates.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import 'cycle_card.dart';
import 'cycle_editor_screen.dart';

class CyclesScreen extends ConsumerWidget {
  const CyclesScreen({super.key});

  void _open(BuildContext context, [Cycle? cycle]) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => CycleEditorScreen(cycle: cycle)),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cycles = ref.watch(cyclesProvider).value ?? const [];
    final active = cycles.where((c) => c.isActive).toList();
    final upcoming = cycles.where((c) => c.isUpcoming).toList();
    final past = cycles.where((c) => !c.isActive && !c.isUpcoming).toList();

    var i = 0;
    Widget stagger(Widget child) =>
        FadeSlideIn.staggered(index: i++, child: child);

    return Scaffold(
      appBar: AppBar(title: const Text('Cycles')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New cycle'),
      ),
      body: cycles.isEmpty
          ? EmptyState(
              icon: Icons.timeline_rounded,
              title: 'No cycles yet',
              message:
                  'A cycle is a block of training with a goal. It sets '
                  'your suggested targets and shades your charts.',
              action: FilledButton(
                onPressed: () => _open(context),
                child: const Text('Start a cycle'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              children: [
                if (active.isNotEmpty) ...[
                  stagger(const SectionHeader('Current')),
                  for (final c in active)
                    stagger(
                      CycleCard(cycle: c, onTap: () => _open(context, c)),
                    ),
                  const SizedBox(height: 20),
                ],
                if (upcoming.isNotEmpty) ...[
                  stagger(const SectionHeader('Upcoming')),
                  for (final c in upcoming)
                    stagger(
                      _CycleTile(cycle: c, onTap: () => _open(context, c)),
                    ),
                  const SizedBox(height: 20),
                ],
                if (past.isNotEmpty) ...[
                  stagger(const SectionHeader('Past')),
                  for (final c in past)
                    stagger(
                      _CycleTile(cycle: c, onTap: () => _open(context, c)),
                    ),
                ],
              ],
            ),
    );
  }
}

class _CycleTile extends StatelessWidget {
  const _CycleTile({required this.cycle, required this.onTap});
  final Cycle cycle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final type = cycle.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: onTap,
        borderRadius: Radii.tile,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.tile),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(type.icon, color: type.color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cycle.name, style: t.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      formatDateRange(cycle.startDate, cycle.endDate),
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (cycle.totalWeeks != null)
                Text(
                  '${cycle.totalWeeks} wk',
                  style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
