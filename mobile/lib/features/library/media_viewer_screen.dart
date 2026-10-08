import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/media_paths.dart';
import '../../domain/enums.dart';

/// Full-screen view of an image (pinch to zoom) or a video with controls.
class MediaViewerScreen extends ConsumerWidget {
  const MediaViewerScreen({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = resolveMediaPath(ref.watch(documentsPathProvider), item.uri);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: item.label == null ? null : Text(item.label!),
      ),
      body: item.kind == MediaKind.video
          ? _VideoView(path: path)
          : Center(
              child: InteractiveViewer(
                maxScale: 5,
                child: Hero(
                  tag: 'media-${item.id}',
                  child: Image.file(File(path)),
                ),
              ),
            ),
    );
  }
}

class _VideoView extends StatefulWidget {
  const _VideoView({required this.path});
  final String path;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  late final VideoPlayerController _c = VideoPlayerController.file(
    File(widget.path),
  );
  bool _showControls = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _c.initialize().then(
      (_) {
        if (!mounted) return;
        _c.setLooping(true);
        _c.play();
        setState(() {});
        _hideSoon();
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
    _c.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _hideSoon() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _c.value.isPlaying) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _c.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(
        child: Text(
          'This video could not be played',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    if (!_c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final v = _c.value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _showControls = !_showControls);
        if (_showControls) _hideSoon();
      },
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: v.aspectRatio,
              child: VideoPlayer(_c),
            ),
          ),
          AnimatedOpacity(
            opacity: _showControls ? 1 : 0,
            duration: Motion.medium,
            child: IgnorePointer(
              ignoring: !_showControls,
              child: Stack(
                children: [
                  Center(
                    child: IconButton.filled(
                      iconSize: 40,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(14),
                      ),
                      onPressed: () {
                        v.isPlaying ? _c.pause() : _c.play();
                        if (!v.isPlaying) _hideSoon();
                      },
                      icon: Icon(
                        v.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 32,
                    child: SafeArea(
                      child: Column(
                        children: [
                          VideoProgressIndicator(
                            _c,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            colors: VideoProgressColors(
                              playedColor: Theme.of(context)
                                  .colorScheme
                                  .primary,
                              bufferedColor: Colors.white24,
                              backgroundColor: Colors.white12,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _fmt(v.position),
                                style: const TextStyle(color: Colors.white70),
                              ),
                              Text(
                                _fmt(v.duration),
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
