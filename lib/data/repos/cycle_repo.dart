import 'package:drift/drift.dart';

import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../db/database.dart';

class CycleRepo {
  CycleRepo(this._db);
  final AppDatabase _db;

  Stream<List<Cycle>> watchForProfile(int profileId) =>
      (_db.select(_db.cycles)
            ..where((c) => c.profileId.equals(profileId))
            ..orderBy([(c) => OrderingTerm.desc(c.startDate)]))
          .watch();

  /// Saves a cycle. Any other cycle still running when this one starts is
  /// ended the day before, so at most one cycle is active at a time.
  Future<int> save({
    int? id,
    required int profileId,
    required CycleType type,
    required String name,
    required DateTime startDate,
    DateTime? endDate,
    double? goalWeightKg,
    String? notes,
  }) {
    final start = dateOnly(startDate);
    final end = endDate == null ? null : dateOnly(endDate);
    return _db.transaction(() async {
      final overlapping =
          await (_db.select(_db.cycles)..where(
                (c) =>
                    c.profileId.equals(profileId) &
                    c.startDate.isSmallerThanValue(start) &
                    (c.endDate.isNull() |
                        c.endDate.isBiggerOrEqualValue(start)),
              ))
              .get();
      for (final c in overlapping) {
        if (c.id == id) continue;
        await (_db.update(_db.cycles)..where((t) => t.id.equals(c.id))).write(
          CyclesCompanion(
            endDate: Value(start.subtract(const Duration(days: 1))),
          ),
        );
      }

      final companion = CyclesCompanion(
        profileId: Value(profileId),
        type: Value(type),
        name: Value(name.trim()),
        startDate: Value(start),
        endDate: Value(end),
        goalWeightKg: Value(goalWeightKg),
        notes: Value(notes?.trim().isEmpty ?? true ? null : notes!.trim()),
      );
      if (id == null) {
        return _db.into(_db.cycles).insert(companion);
      }
      await (_db.update(
        _db.cycles,
      )..where((c) => c.id.equals(id))).write(companion);
      return id;
    });
  }

  Future<void> endToday(int id) =>
      (_db.update(_db.cycles)..where((c) => c.id.equals(id))).write(
        CyclesCompanion(endDate: Value(dateOnly(DateTime.now()))),
      );

  Future<void> delete(int id) =>
      (_db.delete(_db.cycles)..where((c) => c.id.equals(id))).go();
}

extension CycleX on Cycle {
  bool isActiveOn(DateTime day) {
    final d = dateOnly(day);
    return !startDate.isAfter(d) && (endDate == null || !endDate!.isBefore(d));
  }

  bool get isActive => isActiveOn(DateTime.now());
  bool get isUpcoming => startDate.isAfter(dateOnly(DateTime.now()));

  /// 1-based week number of [day] within the cycle.
  int weekOf(DateTime day) =>
      dateOnly(day).difference(startDate).inDays ~/ 7 + 1;

  int? get totalWeeks => endDate == null
      ? null
      : (endDate!.difference(startDate).inDays + 1 + 6) ~/ 7;

  /// Fraction of the cycle elapsed today, or null for open-ended cycles.
  double? get progress {
    if (endDate == null) return null;
    final total = endDate!.difference(startDate).inDays + 1;
    final done = dateOnly(DateTime.now()).difference(startDate).inDays + 1;
    return (done / total).clamp(0.0, 1.0);
  }
}
