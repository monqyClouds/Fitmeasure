import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/sharing.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../library/exercise_detail_screen.dart';
import '../library/muscle_icon.dart';
import '../library/video_links.dart';
import '../live/rooms_api.dart';
import '../plans/plan_screen.dart';
import 'shares_api.dart';

/// What someone shared (from a live.somto.si/s/… link): a preview, and a
/// button to add it.
class ImportShareScreen extends ConsumerStatefulWidget {
  const ImportShareScreen({super.key, required this.shareId});
  final String shareId;

  @override
  ConsumerState<ImportShareScreen> createState() => _ImportShareScreenState();
}

class _ImportShareScreenState extends ConsumerState<ImportShareScreen> {
  late Future<ShareContent?> _share = const SharesApi().find(widget.shareId);
  var _adding = false;

  Future<void> _add(ShareContent share) async {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null || _adding) return;
    setState(() => _adding = true);
    final sharing = ref.read(sharingProvider);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (share.exercise case final e?) {
      final id = await sharing.importExercise(e, profileId);
      messenger.showSnackBar(
        SnackBar(content: Text('${e.name} is in your library')),
      );
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => ExerciseDetailScreen(exerciseId: id)),
      );
    } else {
      final id = await sharing.importPlan(share.plan!, profileId);
      messenger.showSnackBar(
        SnackBar(content: Text('${share.plan!.name} is now your plan')),
      );
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => PlanScreen(planId: id)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shared with you')),
      body: FutureBuilder<ShareContent?>(
        future: _share,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: "Couldn't open it",
              message: snap.error is RoomsApiException
                  ? (snap.error! as RoomsApiException).message
                  : 'Something went wrong.',
              action: FilledButton(
                onPressed: () => setState(
                  () => _share = const SharesApi().find(widget.shareId),
                ),
                child: const Text('Try again'),
              ),
            );
          }
          final share = snap.data;
          if (share == null) {
            return const EmptyState(
              icon: Icons.link_off_rounded,
              title: 'Nothing here',
              message:
                  'This link no longer leads to anything. Shares unopened '
                  'for a year are removed.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              if (share.exercise case final e?)
                _ExercisePreview(exercise: e)
              else
                _PlanPreview(plan: share.plan!),
            ],
          );
        },
      ),
      floatingActionButton: FutureBuilder<ShareContent?>(
        future: _share,
        builder: (context, snap) {
          final share = snap.data;
          if (share == null) return const SizedBox.shrink();
          return FloatingActionButton.extended(
            onPressed: _adding ? null : () => _add(share),
            icon: _adding
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(
              share.exercise != null ? 'Add to my library' : 'Add this plan',
            ),
          );
        },
      ),
    );
  }
}

/// A shared video as a card, without saving anything.
MediaItem _asMedia(SharedVideo v, int i) => MediaItem(
  id: -1 - i,
  profileId: 0,
  exerciseId: 0,
  kind: MediaKind.link,
  uri: v.url,
  label: v.title,
  thumbUrl: '', // YouTube's still is worked out; other sites show a plain card
  createdAt: DateTime(2026),
);

class _ExercisePreview extends StatelessWidget {
  const _ExercisePreview({required this.exercise});
  final SharedExercise exercise;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = exercise;
    final color = e.muscle.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FadeSlideIn(
          child: Row(
            children: [
              MuscleIcon(muscle: e.muscle, size: 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.name, style: t.headlineSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Tag(label: e.muscle.label, color: color),
                        Tag(
                          label: e.equipment.label,
                          color: AppColors.textSecondary,
                        ),
                        Tag(
                          label: e.tracking.label,
                          color: AppColors.textSecondary,
                          icon: e.tracking.icon,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (e.notes != null && e.notes!.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            e.notes!,
            style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 24),
        const SectionHeader('How to do it'),
        if (e.videos.isEmpty)
          Text(
            'No videos came with it.',
            style: t.bodyMedium!.copyWith(color: AppColors.textTertiary),
          )
        else
          SizedBox(
            height: FormVideoStrip.cardWidth * 9 / 16 + 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: e.videos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) =>
                  VideoLinkCard(link: _asMedia(e.videos[i], i), color: color),
            ),
          ),
      ],
    );
  }
}

class _PlanPreview extends StatelessWidget {
  const _PlanPreview({required this.plan});
  final SharedPlan plan;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final exercises = plan.days.fold(0, (n, d) => n + d.items.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(plan.name, style: t.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${plan.days.length} ${plan.days.length == 1 ? 'day' : 'days'} · '
          '$exercises exercises · '
          '${plan.schedule == PlanSchedule.weekly ? 'weekly' : 'in rotation'}',
          style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          'Adding it makes it your active plan. Its exercises join your '
          'library, with their videos.',
          style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 16),
        for (final (i, d) in plan.days.indexed)
          FadeSlideIn.staggered(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      [
                        d.name,
                        if (d.weekday != null)
                          const [
                            'Mon',
                            'Tue',
                            'Wed',
                            'Thu',
                            'Fri',
                            'Sat',
                            'Sun',
                          ][d.weekday! - 1],
                      ].join(' · '),
                      style: t.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final item in d.items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            MuscleIcon(muscle: item.exercise.muscle, size: 34),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.exercise.name, style: t.titleSmall),
                                  Text(
                                    [
                                      describeTargets(
                                        item.exercise.tracking,
                                        sets: item.sets,
                                        reps: item.reps,
                                        weightKg: item.weightKg,
                                        durationSec: item.durationSec,
                                        distanceKm: item.distanceKm,
                                      ),
                                      if (item.restSec != null)
                                        'rest ${formatDuration(item.restSec!)}',
                                    ].join(' · '),
                                    style: t.bodySmall!.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (item.exercise.videos.isNotEmpty)
                              Tag(
                                label: '${item.exercise.videos.length}',
                                color: const Color(0xFFFF0033),
                                icon: Icons.play_arrow_rounded,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
