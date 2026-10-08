import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/link_preview.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import 'media_viewer_screen.dart';

/// Plays a video link: YouTube and video files inside the app, anything
/// else (Instagram, TikTok, …) in the app or browser that owns it.
Future<void> openVideoLink(BuildContext context, MediaItem link) async {
  if (VideoLink.youTubeId(link.uri) case final id?) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            YouTubeScreen(videoId: id, url: link.uri, title: link.label),
      ),
    );
  } else if (VideoLink.isDirectVideo(link.uri)) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MediaViewerScreen(item: link)),
    );
  } else {
    await openExternally(link.uri);
  }
}

Future<void> openExternally(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Opens YouTube's search for videos on doing [exercise] properly.
Future<void> searchFormVideos(String exercise) => launchUrl(
  Uri.https('www.youtube.com', '/results', {
    'search_query': '$exercise proper form',
  }),
  mode: LaunchMode.externalApplication,
);

/// "How to do it": the exercise's video links as a strip of thumbnails, or
/// an invitation to find one.
class FormVideoStrip extends StatelessWidget {
  const FormVideoStrip({
    super.key,
    required this.exerciseName,
    required this.links,
    required this.color,
    required this.onAdd,
    required this.onSearch,
    required this.onActions,
  });

  final String exerciseName;
  final List<MediaItem> links;

  /// The exercise's muscle colour, for cards without a picture.
  final Color color;
  final VoidCallback onAdd;
  final VoidCallback onSearch;
  final ValueChanged<MediaItem> onActions;

  static const cardWidth = 248.0;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return _FindVideoCard(onAdd: onAdd, onSearch: onSearch, color: color);
    }
    return SizedBox(
      height: cardWidth * 9 / 16 + 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: links.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => i == links.length
            ? _AddVideoCard(onTap: onAdd, onSearch: onSearch)
            : FadeSlideIn.staggered(
                index: i,
                child: VideoLinkCard(
                  key: ValueKey(links[i].id),
                  link: links[i],
                  color: color,
                  width: cardWidth,
                  onLongPress: () => onActions(links[i]),
                ),
              ),
      ),
    );
  }
}

/// A video link as a thumbnail card. Looks up the link's picture and title
/// the first time it's shown, if that wasn't done when it was added.
class VideoLinkCard extends ConsumerStatefulWidget {
  const VideoLinkCard({
    super.key,
    required this.link,
    required this.color,
    this.width = FormVideoStrip.cardWidth,
    this.onLongPress,
  });

  final MediaItem link;
  final Color color;
  final double width;
  final VoidCallback? onLongPress;

  @override
  ConsumerState<VideoLinkCard> createState() => _VideoLinkCardState();
}

class _VideoLinkCardState extends ConsumerState<VideoLinkCard> {
  @override
  void initState() {
    super.initState();
    if (widget.link.thumbUrl == null) _lookUp();
  }

  Future<void> _lookUp() async {
    final link = widget.link;
    final p = await ref.read(linkPreviewerProvider).preview(link.uri);
    if (!mounted) return;
    await ref
        .read(exerciseRepoProvider)
        .setPreview(link.id, title: p.title, thumbUrl: p.imageUrl);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final link = widget.link;
    final source = VideoLink.source(link.uri);
    return SizedBox(
      width: widget.width,
      child: Pressable(
        borderRadius: Radii.tile,
        onTap: () => openVideoLink(context, link),
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.tile),
                child: _Thumb(link: link, color: widget.color),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                link.label ?? source,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.titleSmall!.copyWith(height: 1.25),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.link, required this.color});
  final MediaItem link;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final youTube = VideoLink.youTubeId(link.uri);
    final image = youTube != null
        ? VideoLink.youTubeThumb(youTube)
        : (link.thumbUrl?.isNotEmpty ?? false)
        ? link.thumbUrl
        : null;
    final inApp = VideoLink.playsInApp(link.uri);
    final fallback = _NoPicture(color: color, url: link.uri);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image == null)
          fallback
        else
          Image.network(
            image,
            fit: BoxFit.cover,
            cacheWidth: 640,
            errorBuilder: (_, _, _) => fallback,
            frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
              opacity: sync || frame != null ? 1 : 0,
              duration: Motion.medium,
              child: child,
            ),
          ),
        // Darkens the bottom so the badge and button read on any picture.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0x99000000)],
              stops: [0.45, 1],
            ),
          ),
        ),
        Center(
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(
              inApp ? Icons.play_arrow_rounded : Icons.open_in_new_rounded,
              color: Colors.white,
              size: inApp ? 28 : 20,
            ),
          ),
        ),
        Positioned(left: 10, bottom: 10, child: SourceBadge(url: link.uri)),
      ],
    );
  }
}

/// Where a link is from: YouTube in its red, anything else by its address.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final youTube = VideoLink.youTubeId(url) != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: BoxDecoration(
        color: youTube ? const Color(0xFFFF0033) : Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            youTube ? Icons.play_arrow_rounded : Icons.public_rounded,
            size: 14,
            color: Colors.white,
          ),
          const SizedBox(width: 3),
          Text(
            VideoLink.source(url),
            style: Theme.of(context).textTheme.labelSmall!
                .copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// A card for a link whose page offers no picture.
class _NoPicture extends StatelessWidget {
  const _NoPicture({required this.color, required this.url});
  final Color color;
  final String url;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: 0.35), AppColors.surface),
            AppColors.surfaceHigh,
          ],
        ),
      ),
      child: Align(
        alignment: const Alignment(0.85, -0.7),
        child: Icon(
          Icons.smart_display_outlined,
          size: 40,
          color: color.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _AddVideoCard extends StatelessWidget {
  const _AddVideoCard({required this.onTap, required this.onSearch});
  final VoidCallback onTap;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: 132,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 132 / (FormVideoStrip.cardWidth * 9 / 16),
            child: Pressable(
              borderRadius: Radii.tile,
              onTap: onTap,
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.tile),
                  border: Border.all(color: AppColors.outline, width: 1.5),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.add_link_rounded,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(height: 6),
                    Text('Add a video', style: t.labelLarge),
                  ],
                ),
              ),
            ),
          ),
          TextButton(onPressed: onSearch, child: const Text('Find more')),
        ],
      ),
    );
  }
}

/// Shown while an exercise has no video links.
class _FindVideoCard extends StatelessWidget {
  const _FindVideoCard({
    required this.onAdd,
    required this.onSearch,
    required this.color,
  });

  final VoidCallback onAdd;
  final VoidCallback onSearch;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: 0.16), AppColors.surface),
            AppColors.surface,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // A little stack of video frames.
              SizedBox(
                width: 76,
                height: 56,
                child: Stack(
                  children: [
                    for (final (i, a) in [(0, 0.25), (1, 0.45)].reversed)
                      Positioned(
                        left: i * 10.0,
                        top: (1 - i) * 8.0,
                        child: Container(
                          width: 60,
                          height: 40,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: a),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 20,
                      top: 8,
                      child: Container(
                        width: 56,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF0033),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('See how it\'s done', style: t.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      'Find a video showing good form and keep its link '
                      'here, ready to watch.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onSearch,
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Search'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_link_rounded, size: 18),
                  label: const Text('Add link'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A link to add: its address, title and picture ('' for none, null if
/// not looked up).
typedef NewVideoLink = ({String url, String title, String? thumbUrl});

/// Asks for a video link, showing its preview as soon as it's pasted.
Future<NewVideoLink?> showAddVideoSheet(
  BuildContext context, {
  String? initialUrl,
}) => showModalBottomSheet<NewVideoLink>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _AddVideoSheet(initialUrl: initialUrl),
);

class _AddVideoSheet extends ConsumerStatefulWidget {
  const _AddVideoSheet({this.initialUrl});
  final String? initialUrl;

  @override
  ConsumerState<_AddVideoSheet> createState() => _AddVideoSheetState();
}

class _AddVideoSheetState extends ConsumerState<_AddVideoSheet> {
  late final _url = TextEditingController(text: widget.initialUrl);
  final _title = TextEditingController();
  var _titleEdited = false;
  Timer? _debounce;

  /// The preview of [_previewOf]; null while loading.
  LinkPreview? _preview;
  String? _previewOf;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null) _changed();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  String? get _normalized {
    var u = _url.text.trim();
    if (u.isEmpty) return null;
    if (!u.contains('://')) u = 'https://$u';
    final parsed = Uri.tryParse(u);
    return parsed != null && parsed.host.contains('.') ? u : null;
  }

  void _changed() {
    setState(() {});
    _debounce?.cancel();
    final url = _normalized;
    if (url == null || url == _previewOf) return;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() {
        _previewOf = url;
        _preview = null;
      });
      final p = await ref.read(linkPreviewerProvider).preview(url);
      if (!mounted || _previewOf != url) return;
      setState(() => _preview = p);
      if (!_titleEdited && p.title != null) _title.text = p.title!;
    });
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.trim().isEmpty) return;
    _url.text = extractUrl(text) ?? text.trim();
    _changed();
  }

  void _add() {
    final url = _normalized;
    if (url == null) return;
    final ready = _previewOf == url ? _preview : null;
    Navigator.pop<NewVideoLink>(context, (
      url: url,
      title: _title.text,
      thumbUrl: ready == null ? null : ready.imageUrl ?? '',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final url = _normalized;
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
          Text('Add a video', style: t.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Paste a link from YouTube, Instagram, TikTok or any site.',
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            autofocus: widget.initialUrl == null,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://…',
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _paste,
              ),
            ),
            onChanged: (_) => _changed(),
          ),
          AnimatedSize(
            duration: Motion.medium,
            curve: Motion.enter,
            child: url == null || _previewOf == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _PreviewCard(url: _previewOf!, preview: _preview),
                  ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Title (optional)'),
            onChanged: (_) => _titleEdited = true,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: url == null ? null : _add,
            child: const Text('Add video'),
          ),
        ],
      ),
    );
  }
}

/// The first web address in [text], which may be a whole shared message
/// ("Check this out https://youtu.be/…").
String? extractUrl(String text) =>
    RegExp(r'https?://\S+').firstMatch(text)?.group(0);

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.url, required this.preview});
  final String url;
  final LinkPreview? preview;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = preview;
    final image = p?.imageUrl;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: p == null
                    ? const ColoredBox(
                        color: AppColors.surfaceHighest,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : image == null
                    ? const ColoredBox(
                        color: AppColors.surfaceHighest,
                        child: Icon(
                          Icons.smart_display_outlined,
                          color: AppColors.textTertiary,
                        ),
                      )
                    : Image.network(
                        image,
                        fit: BoxFit.cover,
                        cacheWidth: 320,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: AppColors.surfaceHighest),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SourceBadge(url: url),
                const SizedBox(height: 6),
                Text(
                  p == null
                      ? 'Looking it up…'
                      : p.title ??
                            (VideoLink.playsInApp(url)
                                ? 'Video'
                                : 'No preview, but the link will work'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall!.copyWith(color: AppColors.textPrimary),
                ),
                if (p != null && !VideoLink.playsInApp(url))
                  Text(
                    'Opens in its own app',
                    style: t.labelSmall!.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What can be done with a link: play it, open it elsewhere, copy, rename,
/// remove.
Future<void> showVideoLinkActions(
  BuildContext context,
  WidgetRef ref,
  MediaItem link,
) {
  final repo = ref.read(exerciseRepoProvider);
  final source = VideoLink.source(link.uri);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      void then(Future<void> Function() action) {
        Navigator.pop(sheet);
        action();
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                link.label ?? source,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            if (VideoLink.playsInApp(link.uri))
              ListTile(
                leading: const Icon(Icons.play_circle_outline_rounded),
                title: const Text('Play'),
                onTap: () => then(() => openVideoLink(context, link)),
              ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: Text(
                source == 'YouTube' ? 'Open in YouTube' : 'Open $source',
              ),
              onTap: () => then(() => openExternally(link.uri)),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy link'),
              onTap: () => then(() async {
                await Clipboard.setData(ClipboardData(text: link.uri));
              }),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => then(() async {
                final name = await _rename(context, link.label ?? '');
                if (name != null) await repo.setLabel(link.id, name);
              }),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
              ),
              title: const Text(
                'Remove',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () => then(() async {
                final ok = await confirmDialog(
                  context,
                  title: 'Remove this video?',
                  message: 'Its link will be removed from this exercise.',
                  confirmLabel: 'Remove',
                );
                if (ok) await repo.deleteMedia(link);
              }),
            ),
          ],
        ),
      );
    },
  );
}

Future<String?> _rename(BuildContext context, String current) {
  final c = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename video'),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(c.dispose);
}

/// A YouTube video, played inside the app.
class YouTubeScreen extends StatefulWidget {
  const YouTubeScreen({
    super.key,
    required this.videoId,
    required this.url,
    this.title,
  });

  final String videoId;
  final String url;
  final String? title;

  @override
  State<YouTubeScreen> createState() => _YouTubeScreenState();
}

class _YouTubeScreenState extends State<YouTubeScreen> {
  late final _player = YoutubePlayerController.fromVideoId(
    videoId: widget.videoId,
    autoPlay: true,
    params: const YoutubePlayerParams(
      showFullscreenButton: true,
      strictRelatedVideos: true,
    ),
  );

  @override
  void dispose() {
    _player.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Open in YouTube',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => openExternally(widget.url),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            YoutubePlayer(controller: _player, backgroundColor: Colors.black),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SourceBadge(url: widget.url),
                  if (widget.title != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.title!,
                      style: t.titleMedium!.copyWith(color: Colors.white),
                    ),
                  ],
                ],
              ),
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}
