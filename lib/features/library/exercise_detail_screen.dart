import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../progress/exercise_progress_screen.dart';
import 'exercise_editor_screen.dart';
import 'media_viewer_screen.dart';
import 'muscle_icon.dart';

class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseId});
  final int exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  child: const SectionHeader('Photos & videos'),
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
                if (links.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const SectionHeader('Links'),
                  for (final (i, l) in links.indexed)
                    FadeSlideIn.staggered(
                      index: i,
                      child: _LinkTile(
                        item: l,
                        onDelete: () => _confirmDelete(context, ref, l),
                      ),
                    ),
                ],
                if (media.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Long-press an item to remove it',
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
                leading: const Icon(Icons.link_rounded),
                title: const Text('Web link'),
                subtitle: const Text('YouTube, Instagram, any URL'),
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
    Exercise exercise,
  ) async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LinkForm(),
    );
    if (result == null) return;
    await ref
        .read(exerciseRepoProvider)
        .addLink(
          exerciseId: exercise.id,
          profileId: ref.read(currentProfileIdProvider)!,
          url: result.$1,
          label: result.$2,
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

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final file = File(item.uri);
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

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.item, required this.onDelete});
  final MediaItem item;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final uri = Uri.tryParse(item.uri);
    final host = uri?.host.replaceFirst('www.', '') ?? item.uri;
    final isVideo = host.contains('youtu') || host.contains('vimeo');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        borderRadius: Radii.tile,
        onTap: uri == null
            ? null
            : () => launchUrl(uri, mode: LaunchMode.externalApplication),
        onLongPress: onDelete,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.tile),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isVideo ? Icons.smart_display_outlined : Icons.link_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label ?? host,
                      style: t.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.uri,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkForm extends StatefulWidget {
  const _LinkForm();

  @override
  State<_LinkForm> createState() => _LinkFormState();
}

class _LinkFormState extends State<_LinkForm> {
  final _url = TextEditingController();
  final _label = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  String? get _normalized {
    var u = _url.text.trim();
    if (u.isEmpty) return null;
    if (!u.contains('://')) u = 'https://$u';
    final parsed = Uri.tryParse(u);
    return parsed != null && parsed.host.isNotEmpty ? u : null;
  }

  @override
  Widget build(BuildContext context) {
    final valid = _normalized != null;
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
          Text('Add link', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          TextField(
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: 'https://…'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Label (optional)'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: valid
                ? () => Navigator.pop(context, (_normalized!, _label.text))
                : null,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
