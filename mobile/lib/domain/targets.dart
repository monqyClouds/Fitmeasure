import 'enums.dart';

/// What to aim for with one exercise in a plan or workout.
typedef Targets = ({
  int sets,
  int? reps,
  double? weightKg,
  int? durationSec,
  double? distanceKm,
  int? restSec,
});

/// Suggested targets for a newly added exercise, from the running cycle
/// (or routine defaults when there is none).
Targets defaultTargets(TrackingType tracking, CycleType? cycle) {
  final c = cycle ?? CycleType.routine;
  return switch (tracking) {
    TrackingType.reps => (
      sets: c.sets,
      reps: c.reps,
      weightKg: null,
      durationSec: null,
      distanceKm: null,
      restSec: c.restSec,
    ),
    TrackingType.time => (
      sets: 3,
      reps: null,
      weightKg: null,
      durationSec: 60,
      distanceKm: null,
      restSec: c.restSec,
    ),
    TrackingType.distance => (
      sets: 1,
      reps: null,
      weightKg: null,
      durationSec: null,
      distanceKm: null,
      restSec: null,
    ),
  };
}

/// Rough minutes to get through [items]: working time per set, rest between
/// sets, and a minute to move between exercises.
int estimateMinutes(Iterable<(TrackingType, Targets)> items) {
  var sec = 0;
  for (final (tracking, t) in items) {
    final work = switch (tracking) {
      TrackingType.reps => 45,
      TrackingType.time => t.durationSec ?? 60,
      TrackingType.distance => t.durationSec ?? 20 * 60,
    };
    sec += t.sets * work + (t.sets - 1) * (t.restSec ?? 60) + 60;
  }
  return (sec / 60).round();
}
