import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/plan_repo.dart';
import '../../data/seed/plan_templates.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import 'plan_screen.dart';
import 'plan_visuals.dart';

class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final plans = ref.watch(plansProvider);
    final list = plans.value ?? const <PlanOverview>[];

    return Scaffold(
      floatingActionButton: list.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => startNewPlan(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New plan'),
            ),
      body: GlowBackdrop(
        color: accent,
        secondary: CycleType.endurance.color,
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
            children: [
              FadeSlideIn(child: Text('Plans', style: t.headlineMedium)),
              const SizedBox(height: 4),
              FadeSlideIn(
                child: Text(
                  list.isEmpty
                      ? 'Plan your week, then log it set by set'
                      : list.length == 1
                      ? '1 plan'
                      : '${list.length} plans',
                  style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 22),
              if (plans.hasValue && list.isEmpty)
                const _GetStarted()
              else
                for (final (i, p) in list.indexed)
                  FadeSlideIn.staggered(
                    key: ValueKey(p.plan.id),
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _PlanCard(overview: p),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the new-plan sheet, then the created plan.
Future<void> startNewPlan(BuildContext context, WidgetRef ref) async {
  final id = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _NewPlanSheet(),
  );
  if (id != null && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlanScreen(planId: id)),
    );
  }
}

class _GetStarted extends ConsumerWidget {
  const _GetStarted();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FadeSlideIn(
          child: SurfaceCard(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  accent.withValues(alpha: 0.22),
                  AppColors.surface,
                ),
                AppColors.surface,
              ],
            ),
            child: Row(
              children: [
                const _PlanIllustration(),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pick a starting point', style: t.titleLarge),
                      const SizedBox(height: 6),
                      Text(
                        'Use a proven split and tweak it, or build your '
                        'own from scratch.',
                        style: t.bodyMedium!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        const SectionHeader('Templates'),
        for (final (i, tpl) in planTemplates.indexed)
          FadeSlideIn.staggered(
            index: i + 1,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TemplateCard(
                template: tpl,
                onTap: () async {
                  final id = await createFromTemplate(ref, tpl);
                  if (id != null && context.mounted) {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => PlanScreen(planId: id)),
                    );
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => startNewPlan(context, ref),
          icon: const Icon(Icons.edit_calendar_rounded),
          label: const Text('Build my own'),
        ),
      ],
    );
  }
}

Future<int?> createFromTemplate(WidgetRef ref, PlanTemplate tpl) {
  final profileId = ref.read(currentProfileIdProvider);
  if (profileId == null) return Future.value();
  return ref
      .read(planRepoProvider)
      .createFromTemplate(
        profileId: profileId,
        template: tpl,
        cycle: ref.read(activeCycleProvider)?.type,
      );
}

/// Three stacked calendar cards, drawn rather than shipped as an image.
class _PlanIllustration extends StatelessWidget {
  const _PlanIllustration();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget card(double angle, Color color, double opacity) => Transform.rotate(
      angle: angle,
      child: Container(
        width: 58,
        height: 70,
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            color.withValues(alpha: opacity),
            AppColors.surfaceHigh,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10)],
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 6,
              width: 26,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const Spacer(),
            for (var r = 0; r < 3; r++) ...[
              Row(
                children: [
                  for (var c = 0; c < 4; c++)
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 3, top: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (r * 4 + c) % 3 == 0
                            ? color
                            : AppColors.surfaceHighest,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    return SizedBox(
      width: 88,
      height: 92,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            child: card(-0.22, CycleType.endurance.color, 0.15),
          ),
          Positioned(right: 0, child: card(0.2, CycleType.bulk.color, 0.15)),
          card(0, accent, 0.2),
        ],
      ),
    );
  }
}

class TemplateCard extends StatelessWidget {
  const TemplateCard({super.key, required this.template, required this.onTap});
  final PlanTemplate template;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final previewDays = [
      for (final (i, (name, weekday, _)) in template.days.indexed)
        PlanDay(
          id: -i - 1,
          planId: 0,
          name: name,
          weekday: weekday,
          position: i,
        ),
    ];
    final exerciseCount = template.days.fold(0, (n, d) => n + d.$3.length);
    return Pressable(
      onTap: onTap,
      borderRadius: Radii.tile,
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ScheduleBadge(schedule: template.schedule),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(template.name, style: t.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        template.description,
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textTertiary,
                ),
              ],
            ),
            const SizedBox(height: 14),
            ScheduleStrip(schedule: template.schedule, days: previewDays),
            const SizedBox(height: 10),
            Text(
              '${template.days.length} days · $exerciseCount exercises',
              style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleBadge extends StatelessWidget {
  const _ScheduleBadge({required this.schedule, this.color});
  final PlanSchedule schedule;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(
        schedule == PlanSchedule.weekly
            ? Icons.calendar_view_week_rounded
            : Icons.autorenew_rounded,
        color: c,
        size: 22,
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.overview});
  final PlanOverview overview;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final plan = overview.plan;
    final exercises = [for (final d in overview.days) ...d.exercises];
    return Pressable(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PlanScreen(planId: plan.id)),
      ),
      child: Ink(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          border: plan.active
              ? Border.all(color: accent.withValues(alpha: 0.5), width: 1.5)
              : null,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                accent.withValues(alpha: plan.active ? 0.16 : 0.04),
                AppColors.surface,
              ),
              AppColors.surface,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ScheduleBadge(
                  schedule: plan.schedule,
                  color: plan.active ? accent : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(plan.name, style: t.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        plan.schedule == PlanSchedule.weekly
                            ? 'Weekly'
                            : 'Rotation',
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (plan.active)
                  Tag(label: 'Active', color: accent, icon: Icons.bolt_rounded),
              ],
            ),
            const SizedBox(height: 18),
            ScheduleStrip(
              schedule: plan.schedule,
              days: [for (final d in overview.days) d.day],
              color: plan.active ? accent : AppColors.textSecondary,
            ),
            const SizedBox(height: 18),
            MuscleBalanceBar(exercises: exercises),
            const SizedBox(height: 14),
            Row(
              children: [
                _Metric(
                  icon: Icons.event_repeat_rounded,
                  text: '${overview.days.length} days',
                ),
                const SizedBox(width: 16),
                _Metric(
                  icon: Icons.fitness_center_rounded,
                  text: '${overview.exerciseCount} exercises',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppColors.textTertiary),
        const SizedBox(width: 6),
        Text(
          text,
          style: Theme.of(context).textTheme.labelMedium!
              .copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _NewPlanSheet extends ConsumerStatefulWidget {
  const _NewPlanSheet();

  @override
  ConsumerState<_NewPlanSheet> createState() => _NewPlanSheetState();
}

class _NewPlanSheetState extends ConsumerState<_NewPlanSheet> {
  final _name = TextEditingController();
  var _schedule = PlanSchedule.weekly;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null || _name.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final id = await ref
        .read(planRepoProvider)
        .createPlan(
          profileId: profileId,
          name: _name.text,
          schedule: _schedule,
        );
    if (mounted) Navigator.pop(context, id);
  }

  Future<void> _fromTemplate(PlanTemplate tpl) async {
    if (_busy) return;
    setState(() => _busy = true);
    final id = await createFromTemplate(ref, tpl);
    if (mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        children: [
          Text('New plan', style: t.headlineSmall),
          const SizedBox(height: 20),
          const SectionHeader('Build your own'),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Plan name',
              hintText: 'e.g. Summer strength',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final s in PlanSchedule.values) ...[
                if (s != PlanSchedule.values.first) const SizedBox(width: 10),
                Expanded(
                  child: _ScheduleOption(
                    schedule: s,
                    selected: _schedule == s,
                    onTap: () => setState(() => _schedule = s),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _name.text.trim().isEmpty || _busy ? null : _create,
            child: const Text('Create plan'),
          ),
          const SizedBox(height: 28),
          const SectionHeader('Or start from a template'),
          for (final tpl in planTemplates)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TemplateCard(
                template: tpl,
                onTap: () => _fromTemplate(tpl),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScheduleOption extends StatelessWidget {
  const _ScheduleOption({
    required this.schedule,
    required this.selected,
    required this.onTap,
  });

  final PlanSchedule schedule;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final weekly = schedule == PlanSchedule.weekly;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.standard,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? Color.alphaBlend(
                  accent.withValues(alpha: 0.12),
                  AppColors.surfaceHigh,
                )
              : AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(Radii.tile),
          border: Border.all(
            color: selected ? accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              weekly
                  ? Icons.calendar_view_week_rounded
                  : Icons.autorenew_rounded,
              color: selected ? accent : AppColors.textSecondary,
            ),
            const SizedBox(height: 10),
            Text(weekly ? 'Weekly' : 'Rotation', style: t.titleSmall),
            const SizedBox(height: 2),
            Text(
              weekly
                  ? 'Each day on a set weekday'
                  : 'Day 1, 2, 3… whenever you train',
              style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
