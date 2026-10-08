import '../db/database.dart';

/// App-wide switches, stored as key/value rows.
class SettingsRepo {
  SettingsRepo(this._db);
  final AppDatabase _db;

  static const keepAwake = 'keep_screen_on_during_workouts';
  static const timerSounds = 'timer_sounds';

  Stream<bool> watchBool(String key, {bool fallback = false}) =>
      (_db.select(_db.appSettings)..where((s) => s.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row == null ? fallback : row.value == 'true');

  Future<bool> getBool(String key, {bool fallback = false}) async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row == null ? fallback : row.value == 'true';
  }

  Future<void> setBool(String key, bool value) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: key, value: '$value'),
      );

  Stream<String?> watchString(String key) =>
      (_db.select(_db.appSettings)..where((s) => s.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value);

  Future<String?> getString(String key) async => (await (_db.select(
    _db.appSettings,
  )..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setString(String key, String value) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: key, value: value),
      );
}
