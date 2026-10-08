import '../../data/db/database.dart';
import '../../domain/enums.dart';
import '../../domain/targets.dart';
import '../../domain/units.dart';
import 'live_protocol.dart';

/// A room workout's steps for [items], each exercise's sets in turn: a
/// timed exercise counts down each set; any other waits for the host to
/// move on, showing the target ("12 reps · 40 kg"). Each set is followed
/// by its rest, except the very last.
List<WorkoutStep> workoutSteps(List<(Exercise, Targets)> items) {
  final steps = <WorkoutStep>[];
  for (final (i, (exercise, t)) in items.indexed) {
    final timed =
        exercise.tracking == TrackingType.time && (t.durationSec ?? 0) > 0;
    final detail = timed
        ? null
        : describeSet(
            exercise.tracking,
            reps: t.reps,
            weightKg: t.weightKg,
            durationSec: t.durationSec,
            distanceKm: t.distanceKm,
          );
    final sets = t.sets < 1 ? 1 : t.sets;
    for (var n = 1; n <= sets; n++) {
      steps.add(
        WorkoutStep(
          kind: StepKind.work,
          title: exercise.name,
          detail: detail == null || detail.isEmpty ? null : detail,
          seconds: timed ? t.durationSec! : 0,
          set: n,
          sets: sets,
        ),
      );
      final last = i == items.length - 1 && n == sets;
      final rest = t.restSec ?? 0;
      if (!last && rest > 0) {
        final (nextName, nextSet) = n < sets
            ? (exercise.name, n + 1)
            : (items[i + 1].$1.name, 1);
        steps.add(
          WorkoutStep(
            kind: StepKind.rest,
            title: 'Rest',
            detail: 'Next: $nextName, set $nextSet',
            seconds: rest,
          ),
        );
      }
    }
  }
  return steps;
}

/// How long a workout's timed steps take, in seconds; sets of reps aren't
/// counted.
int timedSeconds(List<WorkoutStep> steps) =>
    steps.fold(0, (sum, s) => sum + s.seconds);
