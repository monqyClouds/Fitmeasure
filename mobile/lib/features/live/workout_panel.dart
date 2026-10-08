import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/timer_face.dart';
import 'live_protocol.dart';
import 'room_client.dart';

const _restColor = Color(0xFF5AA9FF);
const _breakColor = Color(0xFF3DD6C6);

/// The room's workout, above the videos: the current step's countdown, what
/// it is and what's next. The host and moderators also get its controls.
class WorkoutPanel extends StatefulWidget {
  const WorkoutPanel({super.key, required this.client});
  final RoomClient client;

  @override
  State<WorkoutPanel> createState() => _WorkoutPanelState();
}

class _WorkoutPanelState extends State<WorkoutPanel> {
  Timer? _tick;
  int? _lastStep;
  int? _lastSecond;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final w = widget.client.workout;
      if (w == null) return;
      // A tap for each of the last three seconds, and a thump when the step
      // changes, so nobody has to watch the screen.
      if (_lastStep != null && _lastStep != w.index) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      }
      _lastStep = w.index;
      final step = w.step;
      if (w.running && step != null && step.timed) {
        final secs =
            (widget.client.workoutRemaining(DateTime.now()).inMilliseconds /
                    1000)
                .ceil();
        if (secs != _lastSecond && secs <= 3 && secs > 0) {
          HapticFeedback.lightImpact();
          SystemSound.play(SystemSoundType.click);
        }
        _lastSecond = secs;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final w = client.workout;
    return AnimatedSize(
      duration: Motion.medium,
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: w == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _Panel(
                workout: w,
                remaining: client.workoutRemaining(DateTime.now()),
                controls: client.canModerate ? client : null,
              ),
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.workout,
    required this.remaining,
    required this.controls,
  });

  final LiveWorkout workout;
  final Duration remaining;

  /// Set for the host and moderators.
  final RoomClient? controls;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final step = workout.step;
    final color = switch (step?.kind) {
      StepKind.rest => _restColor,
      StepKind.breakTime => _breakColor,
      _ => accent,
    };

    final Widget body;
    if (step == null) {
      body = Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.18),
            ),
            child: Icon(Icons.emoji_events_rounded, color: accent, size: 34),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Workout complete', style: t.titleMedium),
                Text(
                  '${workout.title} · well done, everyone',
                  style: t.bodySmall!.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      final next = workout.next;
      body = Row(
        children: [
          TimerFace(
            label: switch (step.kind) {
              StepKind.rest => 'REST',
              StepKind.breakTime => 'BREAK',
              _ => 'WORK',
            },
            remaining: remaining,
            total: Duration(seconds: step.seconds),
            color: color,
            size: 92,
            paused: !workout.running,
            untimed: step.timed ? null : 'GO',
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (step.kind == StepKind.breakTime) ...[
                      Icon(Icons.water_drop_rounded, size: 18, color: color),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        step.title,
                        style: t.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Text(
                  [
                    if (step.set != null && step.sets != null)
                      'Set ${step.set} of ${step.sets}',
                    ?step.detail,
                  ].join(' · '),
                  style: t.bodyMedium!.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                _StepDots(workout: workout, color: color),
                // A rest already says what's next.
                if (step.kind != StepKind.rest) ...[
                  const SizedBox(height: 4),
                  Text(
                    next == null
                        ? 'Last step'
                        : 'Next: ${next.title}'
                              '${next.timed ? ' · ${formatDuration(next.seconds)}' : ''}',
                    style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(color.withValues(alpha: 0.18), AppColors.surface),
            AppColors.surface,
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          body,
          if (controls != null) ...[
            const SizedBox(height: 4),
            _HostControls(client: controls!, workout: workout),
          ],
        ],
      ),
    );
  }
}

/// How far through the workout we are: one dot per set, filled when done.
class _StepDots extends StatelessWidget {
  const _StepDots({required this.workout, required this.color});
  final LiveWorkout workout;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final sets = [
      for (final (i, s) in workout.steps.indexed)
        if (s.kind == StepKind.work) i,
    ];
    if (sets.length > 40) {
      final done = sets.where((i) => i < workout.index).length;
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: done / sets.length,
          minHeight: 4,
          color: color,
          backgroundColor: color.withValues(alpha: 0.15),
        ),
      );
    }
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final i in sets)
          AnimatedContainer(
            duration: Motion.medium,
            width: i == workout.index ? 14 : 6,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: i < workout.index
                  ? color
                  : i == workout.index
                  ? color.withValues(alpha: 0.8)
                  : color.withValues(alpha: 0.2),
            ),
          ),
      ],
    );
  }
}

class _HostControls extends StatelessWidget {
  const _HostControls({required this.client, required this.workout});
  final RoomClient client;
  final LiveWorkout workout;

  @override
  Widget build(BuildContext context) {
    final finished = workout.step == null;
    final untimed = workout.step != null && !workout.step!.timed;
    void act(String action, {int? seconds}) {
      HapticFeedback.selectionClick();
      client.controlWorkout(action, seconds: seconds);
    }

    return Row(
      children: [
        IconButton(
          tooltip: 'Previous step',
          onPressed: workout.index > 0 ? () => act(WorkoutAction.prev) : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        if (!finished)
          IconButton.filled(
            tooltip: workout.running ? 'Pause' : 'Start',
            onPressed: () => act(
              workout.running ? WorkoutAction.pause : WorkoutAction.start,
            ),
            icon: Icon(
              workout.running ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
        IconButton(
          tooltip: untimed ? 'Done, next' : 'Next step',
          onPressed: finished ? null : () => act(WorkoutAction.next),
          icon: Icon(
            untimed ? Icons.check_circle_rounded : Icons.skip_next_rounded,
          ),
        ),
        PopupMenuButton<int>(
          tooltip: 'Water break',
          icon: const Icon(Icons.water_drop_rounded, color: _breakColor),
          onSelected: (s) => act(WorkoutAction.breakNow, seconds: s),
          itemBuilder: (_) => [
            for (final s in const [30, 60, 90, 120, 180])
              PopupMenuItem(
                value: s,
                child: Text(
                  'Water break, ${s < 60 ? '$s s' : formatDuration(s)}',
                ),
              ),
          ],
        ),
        const Spacer(),
        TextButton(
          onPressed: () async {
            if (!finished &&
                !await confirmDialog(
                  context,
                  title: 'End the workout?',
                  message: 'The timer goes for everyone in the room.',
                  confirmLabel: 'End',
                )) {
              return;
            }
            act(WorkoutAction.stop);
          },
          child: Text(finished ? 'Close' : 'End'),
        ),
      ],
    );
  }
}
