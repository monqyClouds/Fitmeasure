import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/interval_clock.dart';
import '../../domain/units.dart';
import '../../widgets/timer_face.dart';

const restColor = Color(0xFF5AA9FF);
const readyColor = Color(0xFFFFB547);

/// Runs [sets] of [we] as timed sets: a countdown for each, with
/// [restSec] between, logging each set as its time is up. One set, or all
/// that are left back to back (interval rounds).
Future<void> runTimedSets(
  BuildContext context, {
  required WorkoutExercise we,
  required List<int> sets,
  required int workSec,
  int restSec = 0,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => SetTimerScreen(
      we: we,
      phases: intervalPhases(sets: sets, workSec: workSec, restSec: restSec),
      totalSets: we.rowCount,
    ),
  ),
);

class SetTimerScreen extends ConsumerStatefulWidget {
  const SetTimerScreen({
    super.key,
    required this.we,
    required this.phases,
    required this.totalSets,
  });

  final WorkoutExercise we;
  final List<TimerPhase> phases;
  final int totalSets;

  @override
  ConsumerState<SetTimerScreen> createState() => _SetTimerScreenState();
}

class _SetTimerScreenState extends ConsumerState<SetTimerScreen> {
  late final _clock = IntervalClock(widget.phases);
  Timer? _tick;
  int? _lastSecond;
  var _logged = 0;

  @override
  void initState() {
    super.initState();
    _clock.start(DateTime.now());
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _onTick());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _onTick() {
    final now = DateTime.now();
    final ended = _clock.advance(now);
    for (final p in ended) {
      if (p.kind == PhaseKind.work) _log(p.setNumber!, p.seconds);
    }
    if (ended.isNotEmpty) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    } else if (_clock.running) {
      // A tap for each of the last three seconds.
      final secs = (_clock.left(now).inMilliseconds / 1000).ceil();
      if (secs != _lastSecond && secs <= 3 && secs > 0) {
        HapticFeedback.lightImpact();
        SystemSound.play(SystemSoundType.click);
      }
      _lastSecond = secs;
    }
    if (_clock.done) _tick?.cancel();
    if (mounted) setState(() {});
  }

  Future<void> _log(int setNumber, int seconds) async {
    _logged++;
    await ref
        .read(sessionRepoProvider)
        .logSet(
          entry: widget.we.entry,
          setNumber: setNumber,
          durationSec: seconds,
        );
  }

  void _toggle() {
    final now = DateTime.now();
    _clock.running ? _clock.pause(now) : _clock.start(now);
    HapticFeedback.selectionClick();
    setState(() {});
  }

  /// Ends the current phase now. A set cut short is logged with the time
  /// actually done.
  void _skip() {
    final now = DateTime.now();
    final left = _clock.left(now);
    final skipped = _clock.skip(now);
    if (skipped?.kind == PhaseKind.work) {
      final done = skipped!.seconds - left.inSeconds;
      if (done > 0) _log(skipped.setNumber!, done);
    }
    if (_clock.done) _tick?.cancel();
    HapticFeedback.mediumImpact();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    final phase = _clock.phase;
    final muscle = widget.we.exercise.muscle.color;
    final color = switch (phase?.kind) {
      PhaseKind.work || null => muscle,
      PhaseKind.rest => restColor,
      PhaseKind.ready => readyColor,
    };
    final next = _clock.index + 1 < widget.phases.length
        ? widget.phases[_clock.index + 1]
        : null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Stop',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.we.exercise.name),
      ),
      body: AnimatedContainer(
        duration: Motion.slow,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.3),
            radius: 1.1,
            colors: [color.withValues(alpha: 0.22), AppColors.background],
          ),
        ),
        child: SafeArea(
          child: phase == null
              ? _Finished(sets: _logged, color: muscle)
              : Column(
                  children: [
                    const Spacer(),
                    Text(
                      switch (phase.kind) {
                        PhaseKind.ready => 'Set ${phase.setNumber} is next',
                        PhaseKind.work =>
                          'Set ${phase.setNumber} of ${widget.totalSets}',
                        PhaseKind.rest => 'Then set ${phase.setNumber}',
                      },
                      style: t.titleMedium!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TimerFace(
                      label: switch (phase.kind) {
                        PhaseKind.ready => 'GET READY',
                        PhaseKind.work => 'WORK',
                        PhaseKind.rest => 'REST',
                      },
                      remaining: _clock.left(now),
                      total: Duration(seconds: phase.seconds),
                      color: color,
                      size: 280,
                      paused: !_clock.running,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      next == null
                          ? 'Last one'
                          : switch (next.kind) {
                              PhaseKind.rest =>
                                'Next: rest ${formatDuration(next.seconds)}',
                              _ =>
                                'Next: set ${next.setNumber}, '
                                    '${formatDuration(next.seconds)}',
                            },
                      style: t.bodyLarge!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(width: 64),
                        const SizedBox(width: 24),
                        SizedBox.square(
                          dimension: 84,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              shape: const CircleBorder(),
                              padding: EdgeInsets.zero,
                              backgroundColor: color,
                              foregroundColor: onColor(color),
                            ),
                            onPressed: _toggle,
                            child: Icon(
                              _clock.running
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 44,
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        SizedBox.square(
                          dimension: 64,
                          child: IconButton.filledTonal(
                            tooltip: phase.kind == PhaseKind.work
                                ? 'End this set'
                                : 'Skip',
                            onPressed: _skip,
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({required this.sets, required this.color});
  final int sets;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.18),
            ),
            child: Icon(Icons.check_rounded, size: 64, color: color),
          ),
          const SizedBox(height: 24),
          Text('Done', style: t.headlineMedium),
          const SizedBox(height: 6),
          Text(
            sets == 1 ? '1 set logged' : '$sets sets logged',
            style: t.bodyLarge!.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to workout'),
          ),
        ],
      ),
    );
  }
}
