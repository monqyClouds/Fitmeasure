import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/units.dart';
import '../../services/beeper.dart';
import '../../widgets/visuals.dart';

class RestState {
  const RestState(this.endsAt, this.totalSec);
  final DateTime endsAt;
  final int totalSec;

  int remainingSec(DateTime now) {
    final ms = endsAt.difference(now).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }
}

/// The countdown between sets. Kept as an end time, so it stays right while
/// the screen is off or the app is in the background.
class RestTimer extends Notifier<RestState?> {
  @override
  RestState? build() => null;

  void start(int seconds) => state = RestState(
    DateTime.now().add(Duration(seconds: seconds)),
    seconds,
  );

  void adjust(int seconds) {
    final s = state;
    if (s == null) return;
    final ends = s.endsAt.add(Duration(seconds: seconds));
    state = ends.isBefore(DateTime.now())
        ? null
        : RestState(ends, (s.totalSec + seconds).clamp(1, 3600));
  }

  void stop() => state = null;
}

final restTimerProvider = NotifierProvider<RestTimer, RestState?>(
  RestTimer.new,
);

/// Bottom bar with the rest countdown ring. Vibrates when rest is over, then
/// hides itself a few seconds later.
class RestTimerBar extends ConsumerStatefulWidget {
  const RestTimerBar({super.key});

  @override
  ConsumerState<RestTimerBar> createState() => _RestTimerBarState();
}

class _RestTimerBarState extends ConsumerState<RestTimerBar> {
  Timer? _tick;
  RestState? _buzzedFor;
  int? _lastSecond;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _sync(RestState? s) {
    if (s == null) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        final current = ref.read(restTimerProvider);
        if (current == null) return;
        final now = DateTime.now();
        final left = current.remainingSec(now);
        if (left != _lastSecond && left > 0 && left <= 3) {
          ref.read(beeperProvider).tick();
        }
        _lastSecond = left;
        if (left == 0 && _buzzedFor != current) {
          _buzzedFor = current;
          ref.read(beeperProvider).go();
          HapticFeedback.vibrate();
          Future.delayed(const Duration(milliseconds: 400), () {
            HapticFeedback.vibrate();
          });
        }
        if (now.difference(current.endsAt) > const Duration(seconds: 4)) {
          ref.read(restTimerProvider.notifier).stop();
        }
        setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final rest = ref.watch(restTimerProvider);
    _sync(rest);

    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.standard,
      alignment: Alignment.bottomCenter,
      child: rest == null
          ? const SizedBox(width: double.infinity)
          : Builder(
              builder: (context) {
                final left = rest.remainingSec(DateTime.now());
                final done = left == 0;
                final notifier = ref.read(restTimerProvider.notifier);
                return Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.12),
                        blurRadius: 24,
                        offset: const Offset(0, -6),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
                      child: Row(
                        children: [
                          ProgressRing(
                            value: done ? 1 : left / rest.totalSec,
                            color: done ? _go : accent,
                            size: 64,
                            stroke: 6,
                            child: done
                                ? const Icon(Icons.bolt_rounded, color: _go)
                                : Text(
                                    formatDuration(left),
                                    style: t.titleSmall,
                                  ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  done ? 'Rest over' : 'Resting',
                                  style: t.titleMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  done
                                      ? 'Time for your next set'
                                      : 'Next set in ${formatDuration(left)}',
                                  style: t.bodySmall!.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!done) ...[
                            _RoundButton(
                              label: '−15',
                              onTap: () => notifier.adjust(-15),
                            ),
                            const SizedBox(width: 6),
                            _RoundButton(
                              label: '+15',
                              onTap: () => notifier.adjust(15),
                            ),
                          ],
                          IconButton(
                            tooltip: done ? 'Dismiss' : 'Skip rest',
                            onPressed: notifier.stop,
                            icon: Icon(
                              done
                                  ? Icons.close_rounded
                                  : Icons.skip_next_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// "Go" green shown when a rest finishes.
const _go = Color(0xFFB8F34A);

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 42,
          child: Center(
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
        ),
      ),
    );
  }
}

/// Time since [since], ticking every second.
class ElapsedText extends StatefulWidget {
  const ElapsedText({super.key, required this.since, this.style});
  final DateTime since;
  final TextStyle? style;

  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sec = DateTime.now().difference(widget.since).inSeconds;
    return Text(
      formatDuration(sec < 0 ? 0 : sec),
      // Digits of equal width, so the clock doesn't jiggle.
      style: (widget.style ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
