import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'live_protocol.dart';
import 'live_session_service.dart';
import 'people_sheet.dart';
import 'prejoin_screen.dart';
import 'room_client.dart';
import 'tile_order.dart';

/// In a room: everyone else in a grid, yourself in a small floating tile,
/// and the controls.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.client});
  final RoomClient client;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  RoomClient get _client => widget.client;
  final _self = RTCVideoRenderer();
  bool _selfReady = false;
  bool _closing = false;

  /// The participant shown large, if any.
  String? _pinned;

  /// Tile order across pages, the page shown, and whether a swipe is under
  /// way (nothing reorders then).
  final _order = TileOrder();
  final _pages = PageController();
  int _page = 0;
  bool _swiping = false;

  /// Speaker promotion depends on time passing, not only on events.
  Timer? _tick;
  StreamSubscription<RoomNotice>? _notices;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _client.addListener(_onChange);
    _self.initialize().then((_) {
      if (!mounted) return;
      _self.srcObject = _client.localStream;
      setState(() => _selfReady = true);
    });
    _notices = _client.notices.listen(_onNotice);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _reorder()) setState(() {});
    });
    _client.join();
    // Keeps camera and mic going if the phone is locked or the app is put
    // in the background, with a notification that can end the session.
    LiveSessionService.start(
      room: _client.room,
      onLeave: () {
        if (mounted && !_closing) _leave();
      },
    );
  }

  void _onNotice(RoomNotice notice) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (notice) {
      case MutedNotice(:final by, :final track):
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '$by turned off your ${track == 'mic' ? 'microphone' : 'camera'}',
            ),
          ),
        );
      case InfoNotice(:final text):
        messenger.showSnackBar(SnackBar(content: Text(text)));
      case UnmuteRequest(:final by, :final track):
        _askToUnmute(by, track);
    }
  }

  /// A moderator asks us to unmute. Only we can, so it's our choice.
  Future<void> _askToUnmute(String by, String track) async {
    final mic = track == 'mic';
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(mic ? Icons.mic_rounded : Icons.videocam_rounded),
        title: Text(mic ? 'Unmute?' : 'Turn on your camera?'),
        content: Text(
          '$by asks you to ${mic ? 'unmute' : 'turn on your camera'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(mic ? 'Unmute' : 'Turn on'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    if (mic) {
      _client.setMic(true);
    } else {
      _client.setCamera(true);
    }
  }

  /// Updates the tile order; reports whether it changed.
  bool _reorder() {
    final host = _client.participants.values
        .where((p) => p.role == Role.host)
        .firstOrNull
        ?.id;
    return _order.update(
      present: _client.participants.values
          .where(_client.inGrid)
          .map((p) => p.id),
      speaking: _client.speaking,
      now: DateTime.now(),
      pinned: _pinned,
      host: host,
      frozen: _swiping,
    );
  }

  void _goTo(int page) {
    _pages.animateToPage(page, duration: Motion.medium, curve: Motion.standard);
  }

  void _onChange() {
    if (!mounted) return;
    if (_client.state == RoomState.ended && !_closing) {
      _closing = true;
      final reason = _client.endReason;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      if (reason != null) {
        messenger.showSnackBar(SnackBar(content: Text(reason)));
      }
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pages.dispose();
    _notices?.cancel();
    LiveSessionService.stop();
    WakelockPlus.disable();
    _client.removeListener(_onChange);
    _self.srcObject = null;
    _self.dispose();
    _client.dispose();
    super.dispose();
  }

  void _leave() {
    _closing = true;
    _client.leave();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final others = _client.participants.values.toList();
    _reorder();
    final pages = _order.pages;
    final page = pages.isEmpty ? 0 : _page.clamp(0, pages.length - 1);
    // Only the current page's tiles get video.
    _client.setOnScreen(pages.isEmpty ? {} : pages[page].toSet());
    final offPageSpeaker = _client.speaking
        .where((id) => _client.participants.containsKey(id))
        .where((id) => _order.pageOf(id) != page)
        .firstOrNull;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _client.leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(
                client: _client,
                onInfo: () => _showLinkSheet(context, _client),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    children: [
                      Positioned.fill(
                        child: others.isEmpty
                            ? _Alone(
                                room: _client.room,
                                connecting:
                                    _client.state == RoomState.connecting,
                              )
                            : _PagedGrid(
                                client: _client,
                                pages: pages,
                                pinned: _pinned,
                                controller: _pages,
                                onPage: (i) => setState(() => _page = i),
                                onSwipe: (on) => setState(() => _swiping = on),
                                onTap: (id) => setState(() {
                                  _pinned = _pinned == id ? null : id;
                                  if (_pinned != null) _goTo(0);
                                }),
                              ),
                      ),
                      if (offPageSpeaker != null)
                        Positioned(
                          top: 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _SpeakingChip(
                              name: _client.participants[offPageSpeaker]!.name,
                              onTap: () => _goTo(_order.pageOf(offPageSpeaker)),
                            ),
                          ),
                        ),
                      if (_selfReady)
                        _FloatingSelf(
                          area: box.biggest,
                          child: _SelfTile(
                            renderer: _self,
                            name: _client.name,
                            cameraOn: _client.cameraOn,
                            micOn: _client.micOn,
                            speaking: _client.speaking.contains(_client.myId),
                            mirror: _client.frontCamera,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (pages.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _PageDots(count: pages.length, current: page),
                ),
              _ControlBar(client: _client, onLeave: _leave),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.client, required this.onInfo});
  final RoomClient client;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final count = client.participants.length + 1;
    final link = client.link;
    final (color, label) = switch (client.state) {
      _ when client.reconnecting => (const Color(0xFFFFB547), 'Reconnecting…'),
      RoomState.connecting => (AppColors.textTertiary, 'Connecting'),
      _ when link.relayed => (const Color(0xFFFFB547), 'Relayed'),
      _ => (const Color(0xFF3DD6C6), 'Connected'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.room, style: t.titleMedium),
                Text(
                  '$count ${count == 1 ? 'person' : 'people'} here',
                  style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(Radii.chip),
            onTap: onInfo,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Tag(
                label: label,
                color: color,
                icon: Icons.network_check_rounded,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Everyone else, six to a page, swiped left and right. A page lays its
/// tiles out to fill the space: in portrait one column for one or two
/// people, then two columns (up to 2 × 3); in landscape up to three columns
/// (3 × 2). A pinned person fills most of the first page, with a strip of
/// two others. Only the current page's tiles get video.
class _PagedGrid extends StatelessWidget {
  const _PagedGrid({
    required this.client,
    required this.pages,
    required this.pinned,
    required this.controller,
    required this.onPage,
    required this.onSwipe,
    required this.onTap,
  });

  final RoomClient client;
  final List<List<String>> pages;
  final String? pinned;
  final PageController controller;
  final ValueChanged<int> onPage;
  final ValueChanged<bool> onSwipe;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Tiles don't reorder while a swipe is under way.
        if (n is ScrollStartNotification) onSwipe(true);
        if (n is ScrollEndNotification) onSwipe(false);
        return false;
      },
      child: PageView.builder(
        controller: controller,
        itemCount: pages.length,
        onPageChanged: onPage,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _Page(
            client: client,
            ids: pages[i],
            pinned: i == 0 ? pinned : null,
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.client,
    required this.ids,
    required this.pinned,
    required this.onTap,
  });

  final RoomClient client;
  final List<String> ids;
  final String? pinned;
  final ValueChanged<String> onTap;

  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    Widget tile(String id) {
      final p = client.participants[id];
      if (p == null) return const SizedBox.shrink();
      return _RemoteTile(
        showVideo: client.canSeeVideoOf(p),
        // A global key: when the order changes (a speaker promoted), Flutter
        // moves the tile with its video surface instead of building a new
        // one, which can show black until it's re-attached.
        key: GlobalObjectKey(p),
        participant: p,
        speaking: client.speaking.contains(id),
        onTap: () => onTap(id),
        onSize: (w, h) => client.reportTile(id, w, h),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final landscape = box.maxWidth > box.maxHeight;
        final tiles = [for (final id in ids) tile(id)];

        if (pinned != null && ids.length > 1) {
          // The pinned person large, the others in a strip beside them.
          final rest = tiles.sublist(1);
          final strip = landscape
              ? Column(children: _spaced(rest, Axis.vertical))
              : Row(children: _spaced(rest, Axis.horizontal));
          final children = [
            Expanded(flex: 3, child: tiles.first),
            const SizedBox(width: gap, height: gap),
            Expanded(child: strip),
          ];
          return landscape
              ? Row(children: children)
              : Column(children: children);
        }

        final n = tiles.length;
        final columns = landscape ? n.clamp(1, 3) : (n <= 2 ? 1 : 2);
        final rows = (n / columns).ceil();
        return Column(
          children: _spaced([
            for (var r = 0; r < rows; r++)
              Row(
                children: _spaced([
                  for (var c = 0; c < columns; c++)
                    r * columns + c < n
                        ? tiles[r * columns + c]
                        : const SizedBox.shrink(), // keep tiles the same size
                ], Axis.horizontal),
              ),
          ], Axis.vertical),
        );
      },
    );
  }

  /// Children expanded equally, with gaps between.
  static List<Widget> _spaced(List<Widget> children, Axis axis) => [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0)
        SizedBox(
          width: axis == Axis.horizontal ? gap : 0,
          height: axis == Axis.vertical ? gap : 0,
        ),
      Expanded(child: children[i]),
    ],
  ];
}

/// Dots for the pages, with the current one long.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.current});
  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: Motion.fast,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == current ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == current ? accent : AppColors.textTertiary,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// Someone speaking on another page; tap to go there.
class _SpeakingChip extends StatelessWidget {
  const _SpeakingChip({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      shape: StadiumBorder(side: BorderSide(color: accent)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq_rounded, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                '$name is speaking',
                style: Theme.of(context).textTheme.labelMedium!
                    .copyWith(color: Colors.white),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteTile extends StatelessWidget {
  const _RemoteTile({
    super.key,
    required this.showVideo,
    required this.participant,
    required this.speaking,
    required this.onTap,
    required this.onSize,
  });

  final RemoteParticipant participant;
  final bool showVideo;
  final bool speaking;
  final VoidCallback onTap;
  final void Function(int width, int height) onSize;

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final name = switch (p.role) {
      _ when p.name.isEmpty => 'Joining…',
      Role.host => '${p.name} · host',
      Role.moderator => '${p.name} · moderator',
      _ => p.name,
    };
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        // Report the size once this frame is laid out; the client only
        // sends it on when it changed.
        final size = box.biggest;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => onSize(
            (size.width * ratio).round(),
            (size.height * ratio).round(),
          ),
        );
        return GestureDetector(
          onTap: onTap,
          child: _Tile(
            name: name,
            micOn: p.mic,
            speaking: speaking,
            video: p.stream != null && p.hasVideo && showVideo
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      RTCVideoView(
                        p.renderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                      // Until the first frame is decoded (after joining, or
                      // swiping to their page) show who it is, not black.
                      ValueListenableBuilder(
                        valueListenable: p.renderer,
                        builder: (_, value, _) => value.width == 0
                            ? _Placeholder(name: p.name)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  )
                : _Placeholder(name: p.name),
          ),
        );
      },
    );
  }
}

class _SelfTile extends StatelessWidget {
  const _SelfTile({
    required this.renderer,
    required this.name,
    required this.cameraOn,
    required this.micOn,
    required this.speaking,
    required this.mirror,
  });

  final RTCVideoRenderer renderer;
  final String name;
  final bool cameraOn;
  final bool micOn;
  final bool speaking;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    return _Tile(
      name: 'You',
      small: true,
      micOn: micOn,
      speaking: speaking,
      video: cameraOn
          ? RTCVideoView(
              renderer,
              mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          : _Placeholder(name: name, small: true),
    );
  }
}

/// A video tile: the picture (or a placeholder), the name with a muted-mic
/// mark, and an accent border that lights up while they speak.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.name,
    required this.video,
    this.small = false,
    this.micOn = true,
    this.speaking = false,
  });
  final String name;
  final Widget video;
  final bool small;
  final bool micOn;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(small ? Radii.chip : Radii.tile);
    final accent = Theme.of(context).colorScheme.primary;
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: AppColors.surface),
              video,
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!micOn) ...[
                        const Icon(
                          Icons.mic_off_rounded,
                          size: 14,
                          color: AppColors.danger,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        name,
                        style: Theme.of(context).textTheme.labelMedium!
                            .copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        IgnorePointer(
          child: AnimatedContainer(
            duration: Motion.fast,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: speaking ? accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name, this.small = false});
  final String name;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.profileColors;
    final color = colors[name.hashCode.abs() % colors.length];
    return ColoredBox(
      color: color.withValues(alpha: 0.12),
      child: Center(
        child: ProfileAvatar(name: name, color: color, size: small ? 40 : 84),
      ),
    );
  }
}

/// The empty room: an invitation to share its name.
class _Alone extends StatelessWidget {
  const _Alone({required this.room, required this.connecting});
  final String room;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            else
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(Radii.card),
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  size: 40,
                  color: AppColors.textSecondary,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              connecting ? 'Joining…' : "You're the only one here",
              style: t.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Ask your training partners to join the room "$room".',
              style: t.bodyMedium!.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Your own camera in a corner. Drag it anywhere; it settles in the nearest
/// corner.
class _FloatingSelf extends StatefulWidget {
  const _FloatingSelf({required this.area, required this.child});
  final Size area;
  final Widget child;

  @override
  State<_FloatingSelf> createState() => _FloatingSelfState();
}

class _FloatingSelfState extends State<_FloatingSelf> {
  static const _size = Size(104, 150);
  static const _margin = 12.0;
  Offset? _drag;
  Alignment _corner = Alignment.bottomRight;

  Offset _cornerOffset(Alignment a) {
    final maxX = widget.area.width - _size.width - _margin;
    final maxY = widget.area.height - _size.height - _margin;
    return Offset(a.x < 0 ? _margin : maxX, a.y < 0 ? _margin : maxY);
  }

  @override
  Widget build(BuildContext context) {
    final pos = _drag ?? _cornerOffset(_corner);
    return AnimatedPositioned(
      duration: _drag == null ? Motion.medium : Duration.zero,
      curve: Motion.enter,
      left: pos.dx,
      top: pos.dy,
      width: _size.width,
      height: _size.height,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => _drag = (_drag ?? pos) + d.delta),
        onPanEnd: (_) => setState(() {
          final c = _drag! + _size.center(Offset.zero);
          _corner = Alignment(
            c.dx < widget.area.width / 2 ? -1 : 1,
            c.dy < widget.area.height / 2 ? -1 : 1,
          );
          _drag = null;
        }),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.chip),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.client, required this.onLeave});
  final RoomClient client;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          RoundToggle(
            on: client.micOn,
            onIcon: Icons.mic_rounded,
            offIcon: Icons.mic_off_rounded,
            onChanged: client.setMic,
          ),
          RoundToggle(
            on: client.cameraOn,
            onIcon: Icons.videocam_rounded,
            offIcon: Icons.videocam_off_rounded,
            onChanged: client.setCamera,
          ),
          RoundToggle(
            on: true,
            onIcon: Icons.cameraswitch_rounded,
            offIcon: Icons.cameraswitch_rounded,
            onChanged: client.cameraOn ? (_) => client.flipCamera() : null,
          ),
          Badge(
            isLabelVisible: client.participants.isNotEmpty,
            label: Text('${client.participants.length + 1}'),
            child: RoundToggle(
              on: true,
              onIcon: Icons.people_alt_rounded,
              offIcon: Icons.people_alt_rounded,
              onChanged: (_) => showPeopleSheet(context, client),
            ),
          ),
          Tooltip(
            message: 'Leave',
            child: Material(
              color: AppColors.danger,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onLeave,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showLinkSheet(BuildContext context, RoomClient client) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final link = client.link;
        final t = Theme.of(context).textTheme;
        // Full quality from everyone here: their full layer and audio.
        final downloadNeed = client.participants.length * 1240;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Connection', style: t.titleLarge),
              const SizedBox(height: 16),
              _Meter(
                label: 'Upload',
                kbps: link.uploadKbps,
                needKbps: fullQualityKbps,
                note: 'your estimate of what you can send',
              ),
              if (downloadNeed > 0) ...[
                const SizedBox(height: 14),
                _Meter(
                  label: 'Download',
                  kbps: link.downloadKbps,
                  needKbps: downloadNeed,
                  note:
                      "the server's estimate; it picks each person's "
                      'quality to fit',
                ),
              ],
              const SizedBox(height: 16),
              _InfoRow('Sending', link.sending ?? '—'),
              _InfoRow('Path', link.path ?? '—'),
              _InfoRow(
                'Round trip',
                link.roundTripMs == null ? '—' : '${link.roundTripMs} ms',
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// A bandwidth estimate as a bar against what full quality needs.
class _Meter extends StatelessWidget {
  const _Meter({
    required this.label,
    required this.kbps,
    required this.needKbps,
    required this.note,
  });

  final String label;
  final int? kbps;
  final int needKbps;
  final String note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fill = kbps == null ? 0.0 : (kbps! / needKbps).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 10,
            color: fill >= 1
                ? const Color(0xFF3DD6C6)
                : fill >= 0.45
                ? const Color(0xFFFFB547)
                : AppColors.danger,
            backgroundColor: AppColors.surfaceHigh,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          kbps == null
              ? 'Measuring…'
              : '$kbps kbit/s · full quality needs $needKbps · $note',
          style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: t.bodyMedium!.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Expanded(child: Text(value, style: t.bodyMedium)),
        ],
      ),
    );
  }
}
