import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../domain/enums.dart';
import '../seed/exercise_seed.dart';
import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Profiles,
    Cycles,
    Exercises,
    ExerciseMedia,
    Plans,
    PlanDays,
    PlanItems,
    Sessions,
    SessionExercises,
    SetLogs,
    MeasurementTypes,
    Measurements,
    AppSettings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'fitmeasure'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await batch((b) {
        b.insertAll(exercises, [
          for (final (name, muscle, equipment, tracking) in seedExercises)
            ExercisesCompanion.insert(
              name: name,
              muscle: muscle,
              equipment: equipment,
              tracking: tracking,
            ),
        ]);
      });
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(sessionExercises);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
