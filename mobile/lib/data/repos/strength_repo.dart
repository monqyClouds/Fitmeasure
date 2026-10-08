import 'package:drift/drift.dart';

import '../../domain/strength.dart';
import '../db/database.dart';
import 'live_query.dart';

/// Per-exercise history built from logged sets of finished workouts.
class StrengthRepo {
  StrengthRepo(this._db);
  final AppDatabase _db;

  /// Every exercise the profile has logged, most recently trained first.
  Stream<List<ExerciseTrend>> watchTrends(int profileId) => _db.watchLoad([
    _db.setLogs,
    _db.sessions,
    _db.exercises,
  ], () => _load(profileId));

  Stream<ExerciseTrend?> watchTrend(int profileId, int exerciseId) =>
      _db.watchLoad(
        [_db.setLogs, _db.sessions, _db.exercises],
        () async =>
            (await _load(profileId, exerciseId: exerciseId)).firstOrNull,
      );

  Future<List<ExerciseTrend>> _load(int profileId, {int? exerciseId}) async {
    final query =
        _db.select(_db.setLogs).join([
            innerJoin(
              _db.sessions,
              _db.sessions.id.equalsExp(_db.setLogs.sessionId),
            ),
            innerJoin(
              _db.exercises,
              _db.exercises.id.equalsExp(_db.setLogs.exerciseId),
            ),
          ])
          ..where(
            _db.sessions.profileId.equals(profileId) &
                _db.sessions.endedAt.isNotNull() &
                (exerciseId == null
                    ? const Constant(true)
                    : _db.setLogs.exerciseId.equals(exerciseId)),
          )
          ..orderBy([
            OrderingTerm.asc(_db.sessions.startedAt),
            OrderingTerm.asc(_db.setLogs.setNumber),
          ]);
    final rows = await query.get();

    final exercises = <int, Exercise>{};
    // exercise id → session id → (date, logs), both in date order.
    final grouped = <int, Map<int, (DateTime, List<SetLog>)>>{};
    for (final r in rows) {
      final log = r.readTable(_db.setLogs);
      final session = r.readTable(_db.sessions);
      exercises[log.exerciseId] ??= r.readTable(_db.exercises);
      final bySession = grouped[log.exerciseId] ??= {};
      (bySession[session.id] ??= (session.startedAt, [])).$2.add(log);
    }
    final trends = [
      for (final MapEntry(key: id, value: sessions) in grouped.entries)
        ExerciseTrend(exercises[id]!, [
          for (final MapEntry(key: sid, value: (date, logs))
              in sessions.entries)
            ExerciseSessionStat.from(sid, date, logs),
        ]),
    ]..sort((a, b) => b.lastTrained.compareTo(a.lastTrained));
    return trends;
  }
}
