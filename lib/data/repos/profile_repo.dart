import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../seed/exercise_seed.dart';

class ProfileRepo {
  ProfileRepo(this._db, {Future<Directory> Function()? mediaRoot})
    : _mediaRoot = mediaRoot ?? getApplicationDocumentsDirectory;
  final AppDatabase _db;
  final Future<Directory> Function() _mediaRoot;

  static const _lastProfileKey = 'last_profile_id';

  Stream<List<Profile>> watchAll() => (_db.select(
    _db.profiles,
  )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();

  Stream<Profile?> watch(int id) => (_db.select(
    _db.profiles,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<int> create({required String name, required int color}) {
    return _db.transaction(() async {
      final id = await _db
          .into(_db.profiles)
          .insert(ProfilesCompanion.insert(name: name.trim(), color: color));
      await _db.batch((b) {
        b.insertAll(_db.measurementTypes, [
          for (final (i, (n, unit)) in seedMeasurementTypes.indexed)
            MeasurementTypesCompanion.insert(
              profileId: id,
              name: n,
              unit: unit,
              position: i,
            ),
        ]);
      });
      return id;
    });
  }

  Future<void> update(int id, {required String name, required int color}) =>
      (_db.update(_db.profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(name: Value(name.trim()), color: Value(color)),
      );

  /// Deletes the profile, all of its data and its copied media files.
  Future<void> delete(int id) async {
    await (_db.delete(_db.profiles)..where((t) => t.id.equals(id))).go();
    final dir = Directory(p.join((await _mediaRoot()).path, 'media', '$id'));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<int?> lastUsedId() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_lastProfileKey))).getSingleOrNull();
    return row == null ? null : int.tryParse(row.value);
  }

  Future<void> setLastUsed(int? id) async {
    if (id == null) {
      await (_db.delete(
        _db.appSettings,
      )..where((s) => s.key.equals(_lastProfileKey))).go();
      return;
    }
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: _lastProfileKey, value: '$id'),
        );
  }
}
