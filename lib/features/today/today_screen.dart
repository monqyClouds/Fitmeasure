import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/dates.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../cycles/cycle_card.dart';
import '../cycles/cycle_editor_screen.dart';
import '../cycles/cycles_screen.dart';
import '../profiles/profile_menu_sheet.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final cycle = ref.watch(activeCycleProvider);
    final cyclesLoaded = ref.watch(cyclesProvider).hasValue;
    final t = Theme.of(context).textTheme;

    if (profile == null) return const Scaffold();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            FadeSlideIn(child: _Header(profile: profile)),
            const SizedBox(height: 28),
            if (cyclesLoaded)
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: cycle == null
                    ? _StartCycleCard(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CycleEditorScreen(),
                          ),
                        ),
                      )
                    : CycleCard(
                        cycle: cycle,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CyclesScreen(),
                          ),
                        ),
                      ),
              ),
            const SizedBox(height: 28),
            FadeSlideIn(
              delay: const Duration(milliseconds: 160),
              child: const SectionHeader("Today's workout"),
            ),
            FadeSlideIn(
              delay: const Duration(milliseconds: 200),
              child: SurfaceCard(
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.event_available_rounded,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('No plan yet', style: t.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            'Plans and set logging arrive in the next build.',
                            style: t.bodySmall!.copyWith(
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
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile});
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${greeting(now)},',
                style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 2),
              Text(
                profile.name,
                style: t.headlineMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Pressable(
          borderRadius: 30,
          onTap: () => showProfileMenu(context),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: ProfileAvatar(
              name: profile.name,
              color: Color(profile.color),
              size: 48,
            ),
          ),
        ),
      ],
    );
  }
}

class _StartCycleCard extends StatelessWidget {
  const _StartCycleCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Pressable(
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                accent.withValues(alpha: 0.20),
                AppColors.surface,
              ),
              AppColors.surface,
            ],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start a cycle', style: t.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Bulk, cut, strength, endurance or an ongoing routine. '
                    'Your targets and charts follow it.',
                    style: t.bodyMedium!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Icon(Icons.arrow_forward_rounded, color: onColor(accent)),
            ),
          ],
        ),
      ),
    );
  }
}
