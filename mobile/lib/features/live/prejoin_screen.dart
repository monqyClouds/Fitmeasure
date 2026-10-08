import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'room_client.dart';
import 'session_screen.dart';

/// Camera preview, mic and camera toggles and your name, before joining.
class PreJoinScreen extends StatefulWidget {
  const PreJoinScreen({super.key, required this.room, required this.name});
  final String room;
  final String name;

  @override
  State<PreJoinScreen> createState() => _PreJoinScreenState();
}

class _PreJoinScreenState extends State<PreJoinScreen> {
  final _preview = RTCVideoRenderer();
  late final _name = TextEditingController(text: widget.name);
  MediaStream? _stream;
  String? _error;
  bool _mic = true;
  bool _camera = true;

  /// Set once the stream is handed to the room, which then owns it.
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// Opens the front camera and the mic. On Android this is also when the
  /// permission prompts appear.
  Future<void> _open() async {
    setState(() => _error = null);
    try {
      await _preview.initialize();
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': {
          'facingMode': 'user',
          'width': 960,
          'height': 540,
          'frameRate': 24,
        },
      });
      if (!mounted) {
        await stream.dispose();
        return;
      }
      _preview.srcObject = stream;
      setState(() => _stream = stream);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Fitmeasure needs the camera and microphone for live sessions. '
              'Allow them in Settings, then try again.',
        );
      }
    }
  }

  @override
  void dispose() {
    _preview.srcObject = null;
    _preview.dispose();
    _name.dispose();
    if (!_handedOver) {
      final s = _stream;
      if (s != null) {
        for (final t in s.getTracks()) {
          t.stop();
        }
        s.dispose();
      }
    }
    super.dispose();
  }

  void _setMic(bool on) {
    for (final t in _stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
    setState(() => _mic = on);
  }

  void _setCamera(bool on) {
    for (final t in _stream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
    setState(() => _camera = on);
  }

  void _join() {
    final stream = _stream;
    if (stream == null) return;
    final name = _name.text.trim().isEmpty ? 'Guest' : _name.text.trim();
    _handedOver = true;
    _preview.srcObject = null;
    final client = RoomClient(
      room: widget.room,
      name: name,
      localStream: stream,
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => SessionScreen(client: client)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: Text('Join "${widget.room}"')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            AspectRatio(
              aspectRatio: 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: AppColors.surfaceHigh),
                    if (_stream != null && _camera)
                      RTCVideoView(
                        _preview,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit
                            .RTCVideoViewObjectFitCover,
                      )
                    else
                      Center(
                        child: _error != null
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.no_photography_outlined,
                                      size: 40,
                                      color: AppColors.textTertiary,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _error!,
                                      textAlign: TextAlign.center,
                                      style: t.bodyMedium!.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    OutlinedButton(
                                      onPressed: _open,
                                      child: const Text('Try again'),
                                    ),
                                  ],
                                ),
                              )
                            : _stream == null
                            ? const CircularProgressIndicator()
                            : ProfileAvatar(
                                name: _name.text.isEmpty ? '?' : _name.text,
                                color: accent,
                                size: 88,
                              ),
                      ),
                    // A silhouette guide: stand where your whole body fits.
                    if (_stream != null && _camera)
                      const IgnorePointer(child: _FramingGuide()),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          RoundToggle(
                            on: _mic,
                            onIcon: Icons.mic_rounded,
                            offIcon: Icons.mic_off_rounded,
                            onChanged: _stream == null ? null : _setMic,
                          ),
                          const SizedBox(width: 16),
                          RoundToggle(
                            on: _camera,
                            onIcon: Icons.videocam_rounded,
                            offIcon: Icons.videocam_off_rounded,
                            onChanged: _stream == null ? null : _setCamera,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              maxLength: 40,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Your name in the room',
                prefixIcon: Icon(Icons.badge_outlined),
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            SurfaceCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.tips_and_updates_rounded, color: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Prop the phone about two metres away so your whole body '
                      'fits the outline, and wear earbuds if you have them.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _stream == null ? null : _join,
              icon: const Icon(Icons.login_rounded),
              label: const Text('Join now'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round mic or camera button: filled when on, red when off.
class RoundToggle extends StatelessWidget {
  const RoundToggle({
    super.key,
    required this.on,
    required this.onIcon,
    required this.offIcon,
    required this.onChanged,
  });

  final bool on;
  final IconData onIcon;
  final IconData offIcon;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: on
          ? Colors.white.withValues(alpha: 0.18)
          : AppColors.danger.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onChanged == null ? null : () => onChanged!(!on),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(on ? onIcon : offIcon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}

/// A dashed outline of a standing person over the preview.
class _FramingGuide extends StatelessWidget {
  const _FramingGuide();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _FramingPainter());
}

class _FramingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final cx = size.width / 2;
    final top = size.height * 0.12;
    final unit = size.height * 0.07;
    final path = Path()
      // Head.
      ..addOval(
        Rect.fromCircle(center: Offset(cx, top + unit), radius: unit * 0.8),
      )
      // Body, from shoulders to feet.
      ..moveTo(cx - unit * 1.6, top + unit * 2.6)
      ..lineTo(cx + unit * 1.6, top + unit * 2.6)
      ..lineTo(cx + unit * 1.1, top + unit * 6.6)
      ..lineTo(cx + unit * 0.9, top + unit * 10.6)
      ..moveTo(cx - unit * 1.6, top + unit * 2.6)
      ..lineTo(cx - unit * 1.1, top + unit * 6.6)
      ..lineTo(cx - unit * 0.9, top + unit * 10.6);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 12) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FramingPainter old) => false;
}
