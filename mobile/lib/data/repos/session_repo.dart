import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../domain/targets.dart';
import '../db/database.dart';
import 'live_query.dart';

class WorkoutExercise {
  const WorkoutExercise(this.entry, this.exercise, this.sets);
  final SessionExercise entry;
  final Exercise exercise;

  /// Logged sets, by set number. Numbers can have gaps when sets are
  /// ticked off out of order.
  final List<SetLog> sets;

  SetLog? logged(int setNumber) =>
      sets.where((s) => s.setNumber == setNumber).firstOrNull;

  /// Rows to show: every planned set, plus any logged beyond the plan.
  int get rowCount =>
      sets.fold(entry.targetSets, (n, s) => s.setNumber > n ? s.setNumber : n);

  Targets get targets => (
    sets: entry.targetSets,
    reps: entry.targetReps,
    weightKg: entry.targetWeightKg,
    durationSec: entry.targetDurationSec,
    distanceKm: entry.targetDistanceKm,
    restSec: entry.restSec,
  );
}

class Workout {
  const Workout(this.session, this.exercises);
  final Session session;
  final List<WorkoutExercise> exercises;

  int get loggedSets => exercises.fold(0, (n, e) => n + e.sets.length);

  /// Planned sets not yet ticked off.
  int get remainingSets => exercises.fold(
    0,
    (n, e) =>
        n +
        [
          for (var i = 1; i <= e.rowCount; i++)
            if (e.logged(i) == null) i,
        ].length,
  );

  /// Kilograms moved: weight × reps summed over every logged set.
  double get volumeKg => exercises.fold(
    0,
    (v, e) => e.sets.fold(v, (v, s) => v + (s.weightKg ?? 0) * (s.reps ?? 0)),
  );
}

class SessionSummary {
  const SessionSummary(this.session, this.sets, this.volumeKg);
  final Session session;
  final int sets;
  final double volumeKg;

  Duration? get duration => session.endedAt?.difference(session.startedAt);
}

class SessionRepo {
  SessionRepo(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;
  final AppDatabase _db;
  final DateTime Function() _now;

  /// Rest longer than this isn't rest between sets, so isn't recorded.
  static const maxRest = Duration(minutes: 30);

  /// The profile's unfinished workout, if any.
  Stream<Session?> watchActive(int profileId) =>
      _activeQuery(profileId).watchSingleOrNull();

  Future<Session?> active(int profileId) =>
      _activeQuery(profileId).getSingleOrNull();

  SimpleSelectStatement<$SessionsTable, Session> _activeQuery(int profileId) =>
      _db.select(_db.sessions)
        ..where((s) => s.profileId.equals(profileId) & s.endedAt.isNull())
        ..orderBy([(s) => OrderingTerm.desc(s.startedAt)])
        ..limit(1);

  /// Starts a workout. With a [planDayId], the day's exercises and targets
  /// are copied in.
  Future<int> start({
    required int profileId,
    required String name,
    int? planDayId,
    int? cycleId,
  }) => _db.transaction(() async {
    final id = await _db
        .into(_db.sessions)
        .insert(
          SessionsCompanion.insert(
            profileId: profileId,
            name: name,
            planDayId: Value(planDayId),
            cycleId: Value(cycleId),
            startedAt: _now(),
          ),
        );
    if (planDayId != null) {
      final items =
          await (_db.select(_db.planItems)
                ..where((i) => i.planDayId.equals(planDayId))
                ..orderBy([(i) => OrderingTerm.asc(i.position)]))
              .get();
      await _db.batch((b) {
        for (final (pos, i) in items.indexed) {
          b.insert(
            _db.sessionExercises,
            SessionExercisesCompanion.insert(
              sessionId: id,
              exerciseId: i.exerciseId,
              position: pos,
              targetSets: i.targetSets,
              targetReps: Value(i.targetReps),
              targetWeightKg: Value(i.targetWeightKg),
              targetDurationSec: Value(i.targetDurationSec),
              targetDistanceKm: Value(i.targetDistanceKm),
              restSec: Value(i.restSec),
            ),
          );
        }
      });
    }
    return id;
  });

  Stream<Workout?> watchWorkout(int sessionId) => _db.watchLoad([
    _db.sessions,
    _db.sessionExercises,
    _db.setLogs,
    _db.exercises,
  ], () => loadWorkout(sessionId));

  Future<Workout?> loadWorkout(int sessionId) async {
    final session = await (_db.select(
      _db.sessions,
    )..where((s) => s.id.equals(sessionId))).getSingleOrNull();
    if (session == null) return null;
    final rows =
        await (_db.select(_db.sessionExercises).join([
                innerJoin(
                  _db.exercises,
                  _db.exercises.id.equalsExp(_db.sessionExercises.exerciseId),
                ),
              ])
              ..where(_db.sessionExercises.sessionId.equals(sessionId))
              ..orderBy([OrderingTerm.asc(_db.sessionExercises.position)]))
            .get();
    final logs =
        await (_db.select(_db.setLogs)
              ..where((l) => l.sessionId.equals(sessionId))
              ..orderBy([(l) => OrderingTerm.asc(l.setNumber)]))
            .get();
    return Workout(session, [
      for (final r in rows)
        WorkoutExercise(
          r.readTable(_db.sessionExercises),
          r.readTable(_db.exercises),
          [
            for (final l in logs)
              if (l.exerciseId == r.readTable(_db.exercises).id) l,
          ],
        ),
    ]);
  }

  /// Adds exercises to the end of a workout, skipping ones already in it.
  Future<void> addExercises(
    int sessionId,
    List<Exercise> exercises, {
    CycleType? cycle,
  }) => _db.transaction(() async {
    final existing = await (_db.select(
      _db.sessionExercises,
    )..where((e) => e.sessionId.equals(sessionId))).get();
    final have = {for (final e in existing) e.exerciseId};
    var pos = existing.length;
    for (final e in exercises) {
      if (!have.add(e.id)) continue;
      final t = defaultTargets(e.tracking, cycle);
      await _db
          .into(_db.sessionExercises)
          .insert(
            SessionExercisesCompanion.insert(
              sessionId: sessionId,
              exerciseId: e.id,
              position: pos++,
              targetSets: t.sets,
              targetReps: Value(t.reps),
              targetWeightKg: Value(t.weightKg),
              targetDurationSec: Value(t.durationSec),
              targetDistanceKm: Value(t.distanceKm),
              restSec: Value(t.restSec),
            ),
          );
    }
  });

  /// Removes an exercise and the sets logged for it from a workout.
  Future<void> removeExercise(SessionExercise entry) =>
      _db.transaction(() async {
        await (_db.delete(_db.setLogs)..where(
              (l) =>
                  l.sessionId.equals(entry.sessionId) &
                  l.exerciseId.equals(entry.exerciseId),
            ))
            .go();
        await (_db.delete(
          _db.sessionExercises,
        )..where((e) => e.id.equals(entry.id))).go();
      });

  Future<void> updateTargets(int entryId, Targets t) =>
      (_db.update(
        _db.sessionExercises,
      )..where((e) => e.id.equals(entryId))).write(
        SessionExercisesCompanion(
          targetSets: Value(t.sets),
          targetReps: Value(t.reps),
          targetWeightKg: Value(t.weightKg),
          targetDurationSec: Value(t.durationSec),
          targetDistanceKm: Value(t.distanceKm),
          restSec: Value(t.restSec),
        ),
      );

  Future<void> setTargetSets(int entryId, int sets) =>
      (_db.update(_db.sessionExercises)..where((e) => e.id.equals(entryId)))
          .write(SessionExercisesCompanion(targetSets: Value(sets)));

  /// Records set [setNumber] of an exercise. Rest is the time since the
  /// previous set in the workout finished. Logging a set again corrects its
  /// values but keeps when it was done.
  Future<int> logSet({
    required SessionExercise entry,
    required int setNumber,
    int? reps,
    double? weightKg,
    int? durationSec,
    double? distanceKm,
  }) => _db.transaction(() async {
    final values = SetLogsCompanion(
      reps: Value(reps),
      weightKg: Value(weightKg),
      durationSec: Value(durationSec),
      distanceKm: Value(distanceKm),
    );
    final existing =
        await (_db.select(_db.setLogs)..where(
              (l) =>
                  l.sessionId.equals(entry.sessionId) &
                  l.exerciseId.equals(entry.exerciseId) &
                  l.setNumber.equals(setNumber),
            ))
            .getSingleOrNull();
    if (existing != null) {
      await (_db.update(
        _db.setLogs,
      )..where((l) => l.id.equals(existing.id))).write(values);
      return existing.id;
    }

    final now = _now();
    final previous =
        await (_db.select(_db.setLogs)
              ..where((l) => l.sessionId.equals(entry.sessionId))
              ..orderBy([(l) => OrderingTerm.desc(l.completedAt)])
              ..limit(1))
            .getSingleOrNull();
    final rest = previous == null ? null : now.difference(previous.completedAt);
    return _db
        .into(_db.setLogs)
        .insert(
          values.copyWith(
            sessionId: Value(entry.sessionId),
            exerciseId: Value(entry.exerciseId),
            setNumber: Value(setNumber),
            targetReps: Value(entry.targetReps),
            targetWeightKg: Value(entry.targetWeightKg),
            targetDurationSec: Value(entry.targetDurationSec),
            targetDistanceKm: Value(entry.targetDistanceKm),
            restSec: Value(
              rest == null || rest > maxRest || rest.isNegative
                  ? null
                  : rest.inSeconds,
            ),
            completedAt: Value(now),
          ),
        );
  });

  Future<void> unlogSet(int setLogId) =>
      (_db.delete(_db.setLogs)..where((l) => l.id.equals(setLogId))).go();

  Future<void> finish(int sessionId) =>
      (_db.update(_db.sessions)..where((s) => s.id.equals(sessionId))).write(
        SessionsCompanion(endedAt: Value(_now())),
      );

  /// Deletes a workout and everything logged in it.
  Future<void> delete(int sessionId) =>
      (_db.delete(_db.sessions)..where((s) => s.id.equals(sessionId))).go();

  /// Finished workouts, newest first, with set counts and volume.
  Stream<List<SessionSummary>> watchRecent(int profileId, {int limit = 20}) {
    final sets = _db.setLogs.id.count();
    final volume = (_db.setLogs.weightKg * _db.setLogs.reps.cast<double>())
        .sum();
    final query =
        _db.select(_db.sessions).join([
            leftOuterJoin(
              _db.setLogs,
              _db.setLogs.sessionId.equalsExp(_db.sessions.id),
              useColumns: false,
            ),
          ])
          ..addColumns([sets, volume])
          ..where(
            _db.sessions.profileId.equals(profileId) &
                _db.sessions.endedAt.isNotNull(),
          )
          ..groupBy([_db.sessions.id])
          ..orderBy([OrderingTerm.desc(_db.sessions.startedAt)])
          ..limit(limit);
    return query.watch().map(
      (rows) => [
        for (final r in rows)
          SessionSummary(
            r.readTable(_db.sessions),
            r.read(sets) ?? 0,
            r.read(volume) ?? 0,
          ),
      ],
    );
  }

  /// Exercises where [sessionId] beat the heaviest weight from every earlier
  /// workout of the profile, with the new best. First attempts don't count.
  Future<Map<int, double>> weightRecords(int sessionId) async {
    final session = await (_db.select(
      _db.sessions,
    )..where((s) => s.id.equals(sessionId))).getSingleOrNull();
    if (session == null) return const {};
    final logs = await (_db.select(
      _db.setLogs,
    )..where((l) => l.sessionId.equals(sessionId))).get();
    final best = <int, double>{};
    for (final l in logs) {
      final w = l.weightKg;
      if (w == null || w <= 0) continue;
      if (w > (best[l.exerciseId] ?? 0)) best[l.exerciseId] = w;
    }
    final records = <int, double>{};
    final maxWeight = _db.setLogs.weightKg.max();
    for (final MapEntry(key: exerciseId, value: weight) in best.entries) {
      final row =
          await (_db.selectOnly(_db.setLogs).join([
                  innerJoin(
                    _db.sessions,
                    _db.sessions.id.equalsExp(_db.setLogs.sessionId),
                    useColumns: false,
                  ),
                ])
                ..addColumns([maxWeight])
                ..where(
                  _db.setLogs.exerciseId.equals(exerciseId) &
                      _db.sessions.profileId.equals(session.profileId) &
                      _db.sessions.startedAt.isSmallerThanValue(
                        session.startedAt,
                      ),
                ))
              .getSingle();
      final previous = row.read(maxWeight);
      if (previous != null && weight > previous) records[exerciseId] = weight;
    }
    return records;
  }

  /// The sets of [exerciseId] from the profile's most recent finished
  /// workout that included it, other than [excludeSessionId].
  Future<List<SetLog>> lastSets({
    required int profileId,
    required int exerciseId,
    int? excludeSessionId,
  }) async {
    final latest =
        await (_db.select(_db.setLogs).join([
                innerJoin(
                  _db.sessions,
                  _db.sessions.id.equalsExp(_db.setLogs.sessionId),
                  useColumns: false,
                ),
              ])
              ..where(
                _db.setLogs.exerciseId.equals(exerciseId) &
                    _db.sessions.profileId.equals(profileId) &
                    _db.sessions.endedAt.isNotNull() &
                    (excludeSessionId == null
                        ? const Constant(true)
                        : _db.sessions.id.equals(excludeSessionId).not()),
              )
              ..orderBy([OrderingTerm.desc(_db.sessions.startedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (latest == null) return const [];
    final sessionId = latest.readTable(_db.setLogs).sessionId;
    return (_db.select(_db.setLogs)
          ..where(
            (l) =>
                l.sessionId.equals(sessionId) & l.exerciseId.equals(exerciseId),
          )
          ..orderBy([(l) => OrderingTerm.asc(l.setNumber)]))
        .get();
  }
}
