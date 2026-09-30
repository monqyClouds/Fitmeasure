import 'package:drift/drift.dart';

import '../../domain/dates.dart';
import '../db/database.dart';
import 'live_query.dart';

/// One measurement type with its entries, oldest first.
class MeasurementSeries {
  const MeasurementSeries(this.type, this.entries);
  final MeasurementType type;
  final List<Measurement> entries;

  Measurement? get latest => entries.lastOrNull;

  /// Change from the first entry at or after [days] ago (or the one before
  /// the latest, if that's the only recent one) to the latest.
  double? changeOver(int days, DateTime now) {
    if (entries.length < 2) return null;
    final since = dateOnly(now).subtract(Duration(days: days));
    final recent = entries.where((e) => !e.recordedAt.isBefore(since));
    final base = recent.length >= 2
        ? recent.first
        : entries[entries.length - 2];
    return entries.last.value - base.value;
  }

  double? get totalChange =>
      entries.length < 2 ? null : entries.last.value - entries.first.value;
}

class MeasurementRepo {
  MeasurementRepo(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;
  final AppDatabase _db;
  final DateTime Function() _now;

  /// All of the profile's measurement types in order, with their entries.
  Stream<List<MeasurementSeries>> watchAll(int profileId) => _db.watchLoad([
    _db.measurementTypes,
    _db.measurements,
  ], () => _load(profileId));

  Stream<MeasurementSeries?> watchSeries(int profileId, int typeId) =>
      _db.watchLoad(
        [_db.measurementTypes, _db.measurements],
        () async =>
            (await _load(profileId))
                .where((s) => s.type.id == typeId)
                .firstOrNull,
      );

  Future<List<MeasurementSeries>> _load(int profileId) async {
    final types =
        await (_db.select(_db.measurementTypes)
              ..where((t) => t.profileId.equals(profileId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final entries =
        await (_db.select(_db.measurements)
              ..where((m) => m.profileId.equals(profileId))
              ..orderBy([
                (m) => OrderingTerm.asc(m.recordedAt),
                (m) => OrderingTerm.asc(m.id),
              ]))
            .get();
    final byType = <int, List<Measurement>>{};
    for (final e in entries) {
      (byType[e.typeId] ??= []).add(e);
    }
    return [
      for (final t in types) MeasurementSeries(t, byType[t.id] ?? const []),
    ];
  }

  /// Records several measurements taken at the same time, e.g. from the
  /// log sheet. [values] maps measurement type ids to values.
  Future<void> logMany(int profileId, Map<int, double> values, {DateTime? at}) {
    final when = at ?? _now();
    return _db.batch((b) {
      for (final MapEntry(key: typeId, value: v) in values.entries) {
        b.insert(
          _db.measurements,
          MeasurementsCompanion.insert(
            profileId: profileId,
            typeId: typeId,
            value: v,
            recordedAt: when,
          ),
        );
      }
    });
  }

  Future<void> update(int id, {required double value, DateTime? at}) =>
      (_db.update(_db.measurements)..where((m) => m.id.equals(id))).write(
        MeasurementsCompanion(
          value: Value(value),
          recordedAt: at == null ? const Value.absent() : Value(at),
        ),
      );

  Future<void> delete(int id) =>
      (_db.delete(_db.measurements)..where((m) => m.id.equals(id))).go();

  Future<int> addType(
    int profileId, {
    required String name,
    required String unit,
  }) async {
    final count = (await (_db.select(
      _db.measurementTypes,
    )..where((t) => t.profileId.equals(profileId))).get()).length;
    return _db
        .into(_db.measurementTypes)
        .insert(
          MeasurementTypesCompanion.insert(
            profileId: profileId,
            name: name.trim(),
            unit: unit.trim(),
            position: count,
          ),
        );
  }

  Future<void> updateType(
    int id, {
    required String name,
    required String unit,
  }) => (_db.update(_db.measurementTypes)..where((t) => t.id.equals(id))).write(
    MeasurementTypesCompanion(
      name: Value(name.trim()),
      unit: Value(unit.trim()),
    ),
  );

  /// Deletes a measurement type and everything recorded for it.
  Future<void> deleteType(int id) =>
      (_db.delete(_db.measurementTypes)..where((t) => t.id.equals(id))).go();

  Future<void> reorderTypes(List<int> ids) => _db.batch((b) {
    for (final (i, id) in ids.indexed) {
      b.update(
        _db.measurementTypes,
        MeasurementTypesCompanion(position: Value(i)),
        where: (t) => t.id.equals(id),
      );
    }
  });
}
