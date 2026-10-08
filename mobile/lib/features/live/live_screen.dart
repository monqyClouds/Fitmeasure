import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import 'prejoin_screen.dart';
import 'room_client.dart';

/// Live tab: pick a room and train together over video.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  final _room = TextEditingController(text: 'gym');
  late Future<bool> _online = liveServerOnline();

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  /// Room names on the server are lowercase letters, digits and dashes.
  String get _roomName => _room.text
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9-]'), '');

  void _join() {
    final room = _roomName;
    if (room.isEmpty) return;
    final profile = ref.read(currentProfileProvider).value;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PreJoinScreen(room: room, name: profile?.name ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    var step = 0;
    Widget stagger(Widget child) =>
        FadeSlideIn.staggered(index: step++, child: child);

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
                  'Train together over video, up to four of you.',
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
                          height: 170,
                          child: _GridIllustration(accent: accent),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _room,
                              textInputAction: TextInputAction.go,
                              onSubmitted: (_) => _join(),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Room',
                                prefixIcon: Icon(Icons.meeting_room_outlined),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Text(
                                'Everyone who joins "${_roomName.isEmpty ? '…' : _roomName}" '
                                'sees each other.',
                                style: t.bodySmall!.copyWith(
                                  color: AppColors.textTertiary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _roomName.isEmpty ? null : _join,
                              icon: const Icon(Icons.videocam_rounded),
                              label: const Text('Join room'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 26),
              stagger(const SectionHeader('How it works')),
              stagger(
                const Row(
                  children: [
                    Expanded(
                      child: _Step(
                        icon: Icons.tag_rounded,
                        color: Color(0xFFA99BFF),
                        title: 'Pick a room',
                        text: 'Share its name with your training partners',
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
            ],
          ),
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
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(14)),
        Paint()..color = c.withValues(alpha: 0.16),
      );
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
      ..shader = LinearGradient(
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
