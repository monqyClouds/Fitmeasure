import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import 'join_room.dart';
import 'room_client.dart';
import 'rooms_api.dart';
import 'saved_rooms.dart';
import 'share_room.dart';

/// Live tab: join a room by its ID or link, or create one, and train
/// together over video.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _code = TextEditingController();
  late Future<bool> _online = liveServerOnline();
  var _finding = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? get _id => normalizeRoomId(_code.text);

  Future<void> _join() async {
    final id = _id;
    if (id == null || _finding) return;
    setState(() => _finding = true);
    await openRoomById(context, ref, id);
    if (mounted) setState(() => _finding = false);
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null) return;
    _code.text = normalizeRoomId(text) ?? text.trim();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final rooms = ref.watch(savedRoomsListProvider).value ?? const [];
    var step = 0;
    Widget stagger(Widget child) =>
        FadeSlideIn.staggered(index: step++, child: child);
    final typed = _code.text.trim();

    return Scaffold(
      body: GlowBackdrop(
        color: accent,
        secondary: const Color(0xFF5AA9FF),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              stagger(
                Row(
                  children: [
                    Expanded(child: Text('Live', style: t.headlineMedium)),
                    _ServerStatus(
                      online: _online,
                      onRetry: () =>
                          setState(() => _online = liveServerOnline()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              stagger(
                Text(
                  'Train together over video, up to 16 of you.',
                  style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 22),
              stagger(
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(Radii.card),
                        ),
                        child: SizedBox(
                          height: 150,
                          child: _GridIllustration(accent: accent),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _code,
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              textCapitalization: TextCapitalization.characters,
                              onSubmitted: (_) => _join(),
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: 'Room ID or link',
                                hintText: 'K7F 3QZ',
                                prefixIcon: const Icon(Icons.tag_rounded),
                                errorText: typed.length >= 6 && _id == null
                                    ? 'Room IDs have six letters and digits'
                                    : null,
                                suffixIcon: IconButton(
                                  tooltip: 'Paste',
                                  icon: const Icon(Icons.content_paste_rounded),
                                  onPressed: _paste,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: _id == null || _finding ? null : _join,
                              icon: _finding
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.videocam_rounded),
                              label: const Text('Join room'),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Expanded(child: Divider()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'or',
                                    style: t.bodySmall!.copyWith(
                                      color: AppColors.textTertiary,
                                    ),
                                  ),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () => createRoomFlow(context, ref),
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('Create a room'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (rooms.isNotEmpty) ...[
                const SizedBox(height: 26),
                stagger(const SectionHeader('Your rooms')),
                for (final r in rooms)
                  stagger(
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SavedRoomTile(
                        room: r,
                        onJoin: () => openRoomById(context, ref, r.id),
                        onShare: () => shareRoom(context, r),
                        onForget: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'Remove ${r.name}?',
                            message: r.created
                                ? 'It leaves your list, and you won\'t host '
                                      'it any more if you join it again.'
                                : 'It leaves your list. You can join again '
                                      'with its ID.',
                            confirmLabel: 'Remove',
                          );
                          if (ok) {
                            await ref.read(savedRoomsProvider).forget(r.id);
                          }
                        },
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 26),
              stagger(const SectionHeader('How it works')),
              stagger(
                const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _Step(
                          icon: Icons.ios_share_rounded,
                          color: Color(0xFFA99BFF),
                          title: 'Share the link',
                          text: 'Or read out the room ID to your partners',
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: _Step(
                          icon: Icons.photo_camera_front_rounded,
                          color: Color(0xFF3DD6C6),
                          title: 'Check your camera',
                          text: 'Prop the phone where your whole body shows',
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: _Step(
                          icon: Icons.headphones_rounded,
                          color: Color(0xFFFFB547),
                          title: 'Wear earbuds',
                          text: 'So the room hears you, not itself',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A room this phone created or joined: tap to join again.
class _SavedRoomTile extends StatelessWidget {
  const _SavedRoomTile({
    required this.room,
    required this.onJoin,
    required this.onShare,
    required this.onForget,
  });

  final LiveRoom room;
  final VoidCallback onJoin;
  final VoidCallback onShare;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.profileColors;
    final color = colors[room.id.hashCode.abs() % colors.length];
    return Pressable(
      borderRadius: Radii.tile,
      onTap: onJoin,
      onLongPress: onForget,
      child: Ink(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(Radii.chip),
              ),
              child: Icon(
                room.created ? Icons.star_rounded : Icons.groups_rounded,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    style: t.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      room.displayId.toUpperCase(),
                      if (room.created) 'You host',
                    ].join('  ·  '),
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Share',
              onPressed: onShare,
              icon: const Icon(
                Icons.ios_share_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerStatus extends StatelessWidget {
  const _ServerStatus({required this.online, required this.onRetry});
  final Future<bool> online;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: online,
      builder: (context, snap) {
        final (color, label) = switch (snap.data) {
          null => (AppColors.textTertiary, 'Checking'),
          true => (const Color(0xFF3DD6C6), 'Server online'),
          false => (AppColors.danger, 'Server offline'),
        };
        return Pressable(
          borderRadius: Radii.chip,
          onTap: snap.data == false ? onRetry : null,
          child: Tag(label: label, color: color, icon: Icons.circle),
        );
      },
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(Radii.chip),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(title, style: t.titleSmall),
          const SizedBox(height: 4),
          Text(
            text,
            style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Four video tiles with people in them and a pulsing "live" dot.
class _GridIllustration extends StatefulWidget {
  const _GridIllustration({required this.accent});
  final Color accent;

  @override
  State<_GridIllustration> createState() => _GridIllustrationState();
}

class _GridIllustrationState extends State<_GridIllustration>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => CustomPaint(
        painter: _GridPainter(accent: widget.accent, pulse: _pulse.value),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.accent, required this.pulse});
  final Color accent;
  final double pulse;

  static const _colors = [
    Color(0xFF5AA9FF),
    Color(0xFFFF7A59),
    Color(0xFF3DD6C6),
    Color(0xFFA99BFF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.18), AppColors.surfaceHigh],
        ).createShader(Offset.zero & size),
    );

    const gap = 8.0;
    const pad = 16.0;
    final tileW = (size.width - pad * 2 - gap) / 2;
    final tileH = (size.height - pad * 2 - gap) / 2;
    for (var i = 0; i < 4; i++) {
      final rect = Rect.fromLTWH(
        pad + (i % 2) * (tileW + gap),
        pad + (i ~/ 2) * (tileH + gap),
        tileW,
        tileH,
      );
      final c = _colors[i];
      final tile = RRect.fromRectAndRadius(rect, const Radius.circular(14));
      canvas.drawRRect(tile, Paint()..color = c.withValues(alpha: 0.16));
      // The person is cut off at the tile's edges, like a real video frame.
      canvas.save();
      canvas.clipRRect(tile);
      // A person: head and shoulders, arms up on alternate tiles.
      final cx = rect.center.dx;
      final unit = rect.height / 6;
      final body = Paint()..color = c.withValues(alpha: 0.75);
      canvas.drawCircle(Offset(cx, rect.top + unit * 2), unit * 0.85, body);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromCenter(
            center: Offset(cx, rect.bottom - unit * 0.6),
            width: unit * 3.2,
            height: unit * 2.4,
          ),
          topLeft: Radius.circular(unit * 1.2),
          topRight: Radius.circular(unit * 1.2),
        ),
        body,
      );
      if (i.isEven) {
        final arm = Paint()
          ..color = c.withValues(alpha: 0.75)
          ..strokeWidth = unit * 0.5
          ..strokeCap = StrokeCap.round;
        for (final side in [-1, 1]) {
          canvas.drawLine(
            Offset(cx + side * unit * 1.3, rect.bottom - unit * 1.5),
            Offset(cx + side * unit * 2.1, rect.top + unit * 0.9),
            arm,
          );
        }
      }
      canvas.restore();
    }

    // "Live" dot with an expanding ring.
    final dot = Offset(size.width - pad - 14, pad + 14);
    final red = AppColors.danger;
    canvas.drawCircle(
      dot,
      5 + 9 * pulse,
      Paint()..color = red.withValues(alpha: 0.5 * (1 - pulse)),
    );
    canvas.drawCircle(dot, 5, Paint()..color = red);
    // A subtle sweep so the card feels alive.
    final sweep = Paint()
      ..shader =
          LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.05),
              Colors.white.withValues(alpha: 0),
            ],
            transform: GradientRotation(math.pi / 5),
          ).createShader(
            Rect.fromLTWH(
              size.width * (pulse * 2 - 1),
              0,
              size.width,
              size.height,
            ),
          );
    canvas.drawRect(Offset.zero & size, sweep);
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.pulse != pulse || old.accent != accent;
}
