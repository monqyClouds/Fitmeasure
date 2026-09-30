import 'dart:math' as math;

import '../data/db/database.dart';
import 'enums.dart';

/// Estimated one-rep max (Epley). A single rep is the weight itself; sets
/// without weight or reps have none.
double? estimateOneRepMax(double? weightKg, int? reps) {
  if (weightKg == null || weightKg <= 0 || reps == null || reps <= 0) {
    return null;
  }
  if (reps == 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

/// How one exercise went in one finished workout.
class ExerciseSessionStat {
  const ExerciseSessionStat({
    required this.sessionId,
    required this.date,
    required this.sets,
    required this.totalReps,
    required this.volumeKg,
    this.bestWeightKg,
    this.repsAtBestWeight,
    this.bestE1rm,
    this.maxReps,
    this.bestDurationSec,
    this.bestDistanceKm,
  });

  factory ExerciseSessionStat.from(
    int sessionId,
    DateTime date,
    List<SetLog> logs,
  ) {
    double? bestWeight;
    int? repsAtBest;
    double? bestE1rm;
    int? maxReps;
    int? bestDuration;
    double? bestDistance;
    var totalReps = 0;
    var volume = 0.0;
    for (final l in logs) {
      final w = l.weightKg;
      final r = l.reps;
      totalReps += r ?? 0;
      volume += (w ?? 0) * (r ?? 0);
      if (w != null &&
          w > 0 &&
          (bestWeight == null ||
              w > bestWeight ||
              (w == bestWeight && (r ?? 0) > (repsAtBest ?? 0)))) {
        bestWeight = w;
        repsAtBest = r;
      }
      final e = estimateOneRepMax(w, r);
      if (e != null && (bestE1rm == null || e > bestE1rm)) bestE1rm = e;
      if (r != null && (maxReps == null || r > maxReps)) maxReps = r;
      final d = l.durationSec;
      if (d != null && (bestDuration == null || d > bestDuration)) {
        bestDuration = d;
      }
      final km = l.distanceKm;
      if (km != null && (bestDistance == null || km > bestDistance)) {
        bestDistance = km;
      }
    }
    return ExerciseSessionStat(
      sessionId: sessionId,
      date: date,
      sets: logs.length,
      totalReps: totalReps,
      volumeKg: volume,
      bestWeightKg: bestWeight,
      repsAtBestWeight: repsAtBest,
      bestE1rm: bestE1rm,
      maxReps: maxReps,
      bestDurationSec: bestDuration,
      bestDistanceKm: bestDistance,
    );
  }

  final int sessionId;
  final DateTime date;
  final int sets;
  final int totalReps;
  final double volumeKg;
  final double? bestWeightKg;
  final int? repsAtBestWeight;
  final double? bestE1rm;
  final int? maxReps;
  final int? bestDurationSec;
  final double? bestDistanceKm;

  /// The headline number to chart for an exercise tracked as [tracking]:
  /// estimated 1RM for weighted lifts, else reps, time or distance.
  double? headline(TrackingType tracking) => switch (tracking) {
    TrackingType.reps => bestE1rm ?? maxReps?.toDouble(),
    TrackingType.time => bestDurationSec?.toDouble(),
    TrackingType.distance => bestDistanceKm ?? bestDurationSec?.toDouble(),
  };
}

/// A best value and when it happened.
typedef Best<T> = ({T value, DateTime date});

/// All-time bests for one exercise.
class ExerciseRecords {
  const ExerciseRecords({
    this.heaviest,
    this.repsAtHeaviest,
    this.bestE1rm,
    this.mostVolume,
    this.mostReps,
    this.longest,
    this.farthest,
  });

  factory ExerciseRecords.from(Iterable<ExerciseSessionStat> history) {
    Best<double>? heaviest;
    int? repsAtHeaviest;
    Best<double>? e1rm;
    Best<double>? volume;
    Best<int>? reps;
    Best<int>? longest;
    Best<double>? farthest;
    for (final s in history) {
      final w = s.bestWeightKg;
      if (w != null && (heaviest == null || w > heaviest.value)) {
        heaviest = (value: w, date: s.date);
        repsAtHeaviest = s.repsAtBestWeight;
      }
      final e = s.bestE1rm;
      if (e != null && (e1rm == null || e > e1rm.value)) {
        e1rm = (value: e, date: s.date);
      }
      if (s.volumeKg > 0 && (volume == null || s.volumeKg > volume.value)) {
        volume = (value: s.volumeKg, date: s.date);
      }
      final r = s.maxReps;
      if (r != null && (reps == null || r > reps.value)) {
        reps = (value: r, date: s.date);
      }
      final d = s.bestDurationSec;
      if (d != null && (longest == null || d > longest.value)) {
        longest = (value: d, date: s.date);
      }
      final km = s.bestDistanceKm;
      if (km != null && (farthest == null || km > farthest.value)) {
        farthest = (value: km, date: s.date);
      }
    }
    return ExerciseRecords(
      heaviest: heaviest,
      repsAtHeaviest: repsAtHeaviest,
      bestE1rm: e1rm,
      mostVolume: volume,
      mostReps: reps,
      longest: longest,
      farthest: farthest,
    );
  }

  final Best<double>? heaviest;
  final int? repsAtHeaviest;
  final Best<double>? bestE1rm;
  final Best<double>? mostVolume;
  final Best<int>? mostReps;
  final Best<int>? longest;
  final Best<double>? farthest;
}

/// An exercise's history across workouts, oldest first.
class ExerciseTrend {
  const ExerciseTrend(this.exercise, this.history);
  final Exercise exercise;
  final List<ExerciseSessionStat> history;

  DateTime get lastTrained => history.last.date;

  List<(DateTime, double)> get points => [
    for (final s in history)
      if (s.headline(exercise.tracking) case final v?) (s.date, v),
  ];

  /// Change of the headline value over the last [days], as a fraction of
  /// where it started (0.05 = +5%). Null without two points to compare.
  double? changeOver(int days, DateTime now) {
    final pts = points;
    if (pts.length < 2) return null;
    final since = now.subtract(Duration(days: days));
    final start = pts.where((p) => !p.$1.isBefore(since)).firstOrNull;
    final base = start == null || start == pts.last
        ? pts[math.max(0, pts.length - 2)]
        : start;
    if (base.$2 == 0) return null;
    return (pts.last.$2 - base.$2) / base.$2;
  }
}
