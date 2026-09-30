import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/exercise_repo.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import 'exercise_detail_screen.dart';
import 'exercise_editor_screen.dart';
import 'muscle_icon.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  MuscleGroup? _muscle;
  bool _customOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ExerciseWithMedia> _filter(List<ExerciseWithMedia> all) {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final e in all)
        if ((_muscle == null || e.exercise.muscle == _muscle) &&
            (!_customOnly || e.exercise.profileId != null) &&
            (q.isEmpty || e.exercise.name.toLowerCase().contains(q)))
          e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final all = ref.watch(libraryProvider).value ?? const [];
    final items = _filter(all);

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add custom exercise',
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ExerciseEditorScreen()),
        ),
        child: const Icon(Icons.add_rounded),
      ),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Library', style: t.headlineMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${all.length} exercises',
                      style: t.bodyMedium!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
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
                                onPressed: () =>
                                    setState(() => _search.clear()),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 64,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  children: [
                    _FilterChip(
                      label: 'All',
                      selected: _muscle == null && !_customOnly,
                      onTap: () => setState(() {
                        _muscle = null;
                        _customOnly = false;
                      }),
                    ),
                    _FilterChip(
                      label: 'My exercises',
                      selected: _customOnly,
                      onTap: () => setState(() => _customOnly = !_customOnly),
                    ),
                    for (final m in MuscleGroup.values)
                      _FilterChip(
                        label: m.label,
                        color: m.color,
                        selected: _muscle == m,
                        onTap: () =>
                            setState(() => _muscle = _muscle == m ? null : m),
                      ),
                  ],
                ),
              ),
            ),
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'Nothing found',
                  message:
                      'Try another search, or add it as your own exercise.',
                  action: OutlinedButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExerciseEditorScreen(
                          initialName: _search.text.trim(),
                        ),
                      ),
                    ),
                    child: const Text('Add custom exercise'),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                sliver: SliverList.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => FadeSlideIn.staggered(
                    key: ValueKey(items[i].exercise.id),
                    index: i,
                    child: _ExerciseTile(item: items[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.medium,
          curve: Motion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.18)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.chip),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.6)
                  : Colors.transparent,
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: Motion.medium,
            style: Theme.of(context).textTheme.labelMedium!.copyWith(
              color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

class _ExerciseTile extends StatelessWidget {
  const _ExerciseTile({required this.item});
  final ExerciseWithMedia item;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = item.exercise;
    return OpenContainer(
      transitionDuration: Motion.slow,
      transitionType: ContainerTransitionType.fadeThrough,
      closedColor: AppColors.surface,
      openColor: AppColors.background,
      middleColor: AppColors.background,
      closedElevation: 0,
      openElevation: 0,
      closedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      openBuilder: (_, _) => ExerciseDetailScreen(exerciseId: e.id),
      // The closed card is also painted mid-transition outside any Material,
      // so it brings its own for the ink splash.
      closedBuilder: (context, open) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                MuscleIcon(muscle: e.muscle),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.name,
                        style: t.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${e.muscle.label} · ${e.equipment.label}',
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (e.profileId != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Tag(
                      label: 'Custom',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (item.mediaCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.perm_media_outlined,
                          size: 16,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${item.mediaCount}',
                          style: t.labelMedium!.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (e.tracking != TrackingType.reps)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      e.tracking.icon,
                      size: 18,
                      color: AppColors.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
