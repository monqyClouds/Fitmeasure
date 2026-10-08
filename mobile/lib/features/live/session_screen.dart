import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'prejoin_screen.dart';
import 'room_client.dart';
import 'video_levels.dart';

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
    _client.join();
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
                            : _Grid(others: others),
                      ),
                      if (_selfReady)
                        _FloatingSelf(
                          area: box.biggest,
                          child: _SelfTile(
                            renderer: _self,
                            name: _client.name,
                            cameraOn: _client.cameraOn,
                            mirror: _client.frontCamera,
                          ),
                        ),
                    ],
                  ),
                ),
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

/// Everyone else, sized to fill the space: one fills it, two stack, three
/// or four make a 2×2 grid.
class _Grid extends StatelessWidget {
  const _Grid({required this.others});
  final List<RemoteParticipant> others;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final p in others) _RemoteTile(key: ValueKey(p.id), participant: p),
    ];
    const gap = 6.0;
    Widget row(List<Widget> children) => Expanded(
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: switch (tiles.length) {
        1 => tiles.first,
        2 => Column(
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(height: gap),
            Expanded(child: tiles[1]),
          ],
        ),
        _ => Column(
          children: [
            row(tiles.sublist(0, 2)),
            const SizedBox(height: gap),
            row(tiles.sublist(2)),
          ],
        ),
      },
    );
  }
}

class _RemoteTile extends StatelessWidget {
  const _RemoteTile({super.key, required this.participant});
  final RemoteParticipant participant;

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final name = p.name.isEmpty ? 'Joining…' : p.name;
    return _Tile(
      name: name,
      video: p.stream != null && p.hasVideo
          ? RTCVideoView(
              p.renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              placeholderBuilder: (_) => _Placeholder(name: name),
            )
          : _Placeholder(name: name),
    );
  }
}

class _SelfTile extends StatelessWidget {
  const _SelfTile({
    required this.renderer,
    required this.name,
    required this.cameraOn,
    required this.mirror,
  });

  final RTCVideoRenderer renderer;
  final String name;
  final bool cameraOn;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    return _Tile(
      name: 'You',
      small: true,
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

class _Tile extends StatelessWidget {
  const _Tile({required this.name, required this.video, this.small = false});
  final String name;
  final Widget video;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(small ? Radii.chip : Radii.tile),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.surface),
          video,
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                name,
                style: Theme.of(context).textTheme.labelMedium!
                    .copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
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
              connecting ? 'Joining…' : "You're the first one here",
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
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            ),
            onPressed: onLeave,
            icon: const Icon(Icons.call_end_rounded),
            label: const Text('Leave'),
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
        final upload = link.uploadKbps;
        // How the upload estimate compares with what full quality needs.
        final fill = upload == null
            ? 0.0
            : (upload / videoLevels.first.minKbps).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Connection', style: t.titleLarge),
              const SizedBox(height: 16),
              Text(
                'Upload',
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
                upload == null
                    ? 'Measuring…'
                    : '$upload kbit/s · full quality needs '
                          '${videoLevels.first.minKbps}',
                style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
              ),
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
