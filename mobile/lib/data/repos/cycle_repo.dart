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

  /// Saves a cycle, keeping cycles from overlapping so at most one is active
  /// on any day. An earlier cycle still running when this one starts is ended
  /// the day before. An open-ended cycle placed before a later one ends the
  /// day before that one starts. Any other overlap with a later cycle (or one
  /// starting the same day) throws [CycleOverlapException] and saves nothing.
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
    final requestedEnd = endDate == null ? null : dateOnly(endDate);
    return _db.transaction(() async {
      final others =
          (await (_db.select(
            _db.cycles,
          )..where((c) => c.profileId.equals(profileId))).get()).where(
            (c) => c.id != id,
          );

      // The first cycle starting on or after this one is the only later
      // cycle that can overlap it.
      Cycle? next;
      for (final c in others) {
        if (c.startDate.isBefore(start)) continue;
        if (next == null || c.startDate.isBefore(next.startDate)) next = c;
      }
      var end = requestedEnd;
      if (next != null) {
        if (end == null && next.startDate.isAfter(start)) {
          end = next.startDate.subtract(const Duration(days: 1));
        } else if (end == null || !end.isBefore(next.startDate)) {
          throw CycleOverlapException(next);
        }
      }

      final overlapping = others.where(
        (c) =>
            c.startDate.isBefore(start) &&
            (c.endDate == null || !c.endDate!.isBefore(start)),
      );
      for (final c in overlapping) {
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

/// Thrown when a cycle being saved would overlap [other], a cycle starting
/// on or after it.
class CycleOverlapException implements Exception {
  const CycleOverlapException(this.other);
  final Cycle other;

  @override
  String toString() =>
      'Overlaps with "${other.name}" '
      '(${formatDateRange(other.startDate, other.endDate)}). '
      'Change the dates, or edit that cycle instead.';
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
