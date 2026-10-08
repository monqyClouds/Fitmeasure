import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/media_paths.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../progress/exercise_progress_screen.dart';
import 'exercise_editor_screen.dart';
import 'media_viewer_screen.dart';
import 'muscle_icon.dart';
import 'video_links.dart';
import '../share/share_actions.dart';

class ExerciseDetailScreen extends ConsumerStatefulWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseId});
  final int exerciseId;

  @override
  ConsumerState<ExerciseDetailScreen> createState() =>
      _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends ConsumerState<ExerciseDetailScreen> {
  late final AppLifecycleListener _lifecycle;

  /// Set while the person is off searching YouTube: when they come back
  /// with a link copied, it's offered straight away.
  var _searching = false;

  int get exerciseId => widget.exerciseId;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _backFromSearch);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _search(Exercise exercise) async {
    _searching = true;
    await searchFormVideos(exercise.name);
  }

  Future<void> _backFromSearch() async {
    if (!_searching) return;
    _searching = false;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final url = text == null ? null : extractUrl(text);
    final exercise = ref.read(exerciseProvider(exerciseId)).value;
    if (url == null || exercise == null || !mounted) return;
    final have = ref.read(exerciseMediaProvider(exerciseId)).value ?? const [];
    if (have.any((m) => m.uri == url)) return;
    await _addLink(context, ref, exercise, initialUrl: url);
  }

  @override
  Widget build(BuildContext context) {
    final exercise = ref.watch(exerciseProvider(exerciseId)).value;
    if (exercise == null) {
      return const Scaffold(backgroundColor: AppColors.background);
    }
    final media =
        ref.watch(exerciseMediaProvider(exerciseId)).value ?? const [];
    final files = media.where((m) => m.kind != MediaKind.link).toList();
    final links = media.where((m) => m.kind == MediaKind.link).toList();
    final t = Theme.of(context).textTheme;
    final color = exercise.muscle.color;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddMedia(context, ref, exercise),
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('Add media'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 220,
            backgroundColor: AppColors.background,
            actions: [
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.ios_share_rounded),
                onPressed: () => shareExercise(context, ref, exercise),
              ),
              if (exercise.profileId != null)
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExerciseEditorScreen(exercise: exercise),
                    ),
                  ),
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsetsDirectional.only(
                start: 56,
                bottom: 16,
                end: 56,
              ),
              title: Text(
                exercise.name,
                style: t.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              background: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.alphaBlend(
                        color.withValues(alpha: 0.28),
                        AppColors.background,
                      ),
                      AppColors.background,
                    ],
                  ),
                ),
                child: Align(
                  alignment: const Alignment(0, -0.1),
                  child: FadeSlideIn(
                    child: MuscleIcon(muscle: exercise.muscle, size: 72),
                  ),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            sliver: SliverList.list(
              children: [
                FadeSlideIn(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Tag(label: exercise.muscle.label, color: color),
                      Tag(
                        label: exercise.equipment.label,
                        color: AppColors.textSecondary,
                      ),
                      Tag(
                        label: exercise.tracking.label,
                        color: AppColors.textSecondary,
                        icon: exercise.tracking.icon,
                      ),
                    ],
                  ),
                ),
                if (exercise.notes != null) ...[
                  const SizedBox(height: 20),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 60),
                    child: Text(
                      exercise.notes!,
                      style: t.bodyLarge!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 70),
                  child: const SectionHeader('How to do it'),
                ),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 90),
                  child: FormVideoStrip(
                    exerciseName: exercise.name,
                    links: links,
                    color: color,
                    onAdd: () => _addLink(context, ref, exercise),
                    onSearch: () => _search(exercise),
                    onActions: (l) => showVideoLinkActions(context, ref, l),
                  ),
                ),
                if (ref.watch(exerciseTrendProvider(exerciseId)).value
                    case final trend?) ...[
                  const SizedBox(height: 24),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 80),
                    child: StrengthTile(trend: trend),
                  ),
                ],
                const SizedBox(height: 28),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 100),
                  child: const SectionHeader('Your photos & videos'),
                ),
                if (files.isEmpty)
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 140),
                    child: _MediaHint(
                      onTap: () => _pickFile(context, ref, exercise),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    itemCount: files.length,
                    itemBuilder: (context, i) => FadeSlideIn.staggered(
                      index: i,
                      child: _MediaThumb(
                        item: files[i],
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MediaViewerScreen(item: files[i]),
                          ),
                        ),
                        onLongPress: () =>
                            _confirmDelete(context, ref, files[i]),
                      ),
                    ),
                  ),
                if (media.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Long-press an item for more options',
                    textAlign: TextAlign.center,
                    style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddMedia(
    BuildContext context,
    WidgetRef ref,
    Exercise exercise,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photo or video from phone'),
                subtitle: const Text('A copy is saved inside the app'),
                onTap: () {
                  Navigator.pop(sheet);
                  _pickFile(context, ref, exercise);
                },
              ),
              ListTile(
                leading: const Icon(Icons.smart_display_outlined),
                title: const Text('Video link'),
                subtitle: const Text('YouTube, Instagram, TikTok, any site'),
                onTap: () {
                  Navigator.pop(sheet);
                  _addLink(context, ref, exercise);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFile(
    BuildContext context,
    WidgetRef ref,
    Exercise exercise,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(type: FileType.media);
    if (files.isEmpty) return;
    final profileId = ref.read(currentProfileIdProvider)!;
    try {
      for (final f in files) {
        await ref
            .read(exerciseRepoProvider)
            .addFile(
              exerciseId: exercise.id,
              profileId: profileId,
              fileName: f.name,
              bytes: f.readAsByteStream(),
            );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            files.length == 1
                ? 'Added ${files.first.name}'
                : 'Added ${files.length} files',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add file: $e')));
    }
  }

  Future<void> _addLink(
    BuildContext context,
    WidgetRef ref,
    Exercise exercise, {
    String? initialUrl,
  }) async {
    final link = await showAddVideoSheet(context, initialUrl: initialUrl);
    if (link == null) return;
    await ref
        .read(exerciseRepoProvider)
        .addLink(
          exerciseId: exercise.id,
          profileId: ref.read(currentProfileIdProvider)!,
          url: link.url,
          label: link.title,
          thumbUrl: link.thumbUrl,
        );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    MediaItem item,
  ) async {
    final ok = await confirmDialog(
      context,
      title: 'Remove this ${item.kind.name}?',
      message: item.kind == MediaKind.link
          ? 'The link will be removed from this exercise.'
          : "The app's copy will be deleted. The original on your phone is "
                'not affected.',
      confirmLabel: 'Remove',
    );
    if (ok) await ref.read(exerciseRepoProvider).deleteMedia(item);
  }
}

class _MediaHint extends StatelessWidget {
  const _MediaHint({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: AppColors.outline, width: 1.5),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.video_library_outlined,
              color: AppColors.textSecondary,
              size: 30,
            ),
            const SizedBox(height: 10),
            Text('Add a form video or photo', style: t.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Pick from your gallery or files',
              style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaThumb extends ConsumerWidget {
  const _MediaThumb({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = File(
      resolveMediaPath(ref.watch(documentsPathProvider), item.uri),
    );
    final missing = !file.existsSync();
    Widget content;
    if (missing) {
      content = const Center(
        child: Icon(Icons.broken_image_outlined, color: AppColors.textTertiary),
      );
    } else if (item.kind == MediaKind.image) {
      content = Hero(
        tag: 'media-${item.id}',
        child: Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: 360,
          width: double.infinity,
          height: double.infinity,
          frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
            opacity: sync || frame != null ? 1 : 0,
            duration: Motion.medium,
            child: child,
          ),
        ),
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.surfaceHighest, AppColors.surfaceHigh],
              ),
            ),
          ),
          const Center(
            child: CircleAvatar(
              radius: 20,
              backgroundColor: Colors.black45,
              child: Icon(Icons.play_arrow_rounded, color: Colors.white),
            ),
          ),
          if (item.label != null)
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                item.label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
      );
    }

    return Pressable(
      borderRadius: 16,
      onTap: missing ? null : onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(color: AppColors.surface, child: content),
      ),
    );
  }
}
