import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import 'profile_editor_sheet.dart';

class ProfilePickerScreen extends ConsumerWidget {
  const ProfilePickerScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final id = await showProfileEditor(context);
    if (id != null) {
      await ref.read(currentProfileIdProvider.notifier).select(id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final t = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: profiles.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) {
              return _Welcome(onStart: () => _add(context, ref));
            }
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
                  sliver: SliverToBoxAdapter(
                    child: FadeSlideIn(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Who's training?", style: t.displaySmall),
                          const SizedBox(height: 8),
                          Text(
                            'Pick your profile to continue',
                            style: t.bodyLarge!.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.92,
                    children: [
                      for (final (i, p) in list.indexed)
                        FadeSlideIn.staggered(
                          index: i + 1,
                          child: _ProfileCard(profile: p),
                        ),
                      FadeSlideIn.staggered(
                        index: list.length + 1,
                        child: _AddCard(onTap: () => _add(context, ref)),
                      ),
                    ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Long-press a profile to edit it',
                      textAlign: TextAlign.center,
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Color(profile.color);
    return Pressable(
      onTap: () =>
          ref.read(currentProfileIdProvider.notifier).select(profile.id),
      onLongPress: () => showProfileEditor(context, profile: profile),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                color.withValues(alpha: 0.16),
                AppColors.surface,
              ),
              AppColors.surface,
            ],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ProfileAvatar(name: profile.name, color: color, size: 76),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: AppColors.outline, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceHigh,
              ),
              child: const Icon(
                Icons.add_rounded,
                size: 32,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Add person',
              style: Theme.of(context).textTheme.titleMedium!
                  .copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),
          FadeSlideIn(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.fitness_center_rounded,
                color: onColor(accent),
                size: 30,
              ),
            ),
          ),
          const SizedBox(height: 32),
          FadeSlideIn(
            delay: const Duration(milliseconds: 90),
            child: Text(
              'Track every rep.\nSee every gain.',
              style: t.displaySmall!.copyWith(height: 1.15),
            ),
          ),
          const SizedBox(height: 16),
          FadeSlideIn(
            delay: const Duration(milliseconds: 180),
            child: Text(
              'Plan your training, log each set against its target, and '
              'watch your body change over time.',
              style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const Spacer(flex: 3),
          FadeSlideIn(
            delay: const Duration(milliseconds: 270),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onStart,
                child: const Text('Create your profile'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
