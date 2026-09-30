import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/measurement_repo.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/repos/session_repo.dart';
import 'package:fitmeasure/data/repos/strength_repo.dart';
import 'package:fitmeasure/domain/strength.dart';
import 'package:fitmeasure/features/progress/progress_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late MeasurementRepo measurements;
  late SessionRepo sessions;
  late StrengthRepo strength;
  late DateTime now;
  late int pid;

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    now = DateTime(2026, 9, 1, 8);
    measurements = MeasurementRepo(db, clock: () => now);
    sessions = SessionRepo(db, clock: () => now);
    strength = StrengthRepo(db);
    pid = await ProfileRepo(db).create(name: 'Ada', color: 1);
  });

  tearDown(() => db.close());

  Future<Exercise> exercise(String name) =>
      (db.select(db.exercises)..where((e) => e.name.equals(name))).getSingle();

  group('measurements', () {
    test(
      'a profile starts with body weight first and nothing logged',
      () async {
        final all = await measurements.watchAll(pid).first;
        expect(all.first.type.name, 'Body weight');
        expect(all.every((s) => s.entries.isEmpty), isTrue);
      },
    );

    test('logging several at once, in date order', () async {
      final all = await measurements.watchAll(pid).first;
      final weight = all[0].type.id;
      final waist = all.firstWhere((s) => s.type.name == 'Waist').type.id;

      await measurements.logMany(pid, {weight: 82.4, waist: 88});
      await measurements.logMany(pid, {weight: 83.0}, at: DateTime(2026, 8, 1));
      now = DateTime(2026, 9, 15);
      await measurements.logMany(pid, {weight: 81.6});

      final series = (await measurements.watchSeries(pid, weight).first)!;
      expect([for (final e in series.entries) e.value], [83.0, 82.4, 81.6]);
      expect(series.latest!.value, 81.6);
      expect(series.totalChange, closeTo(-1.4, 1e-9));
      // Over 30 days from 15 Sep: from 82.4 (1 Sep) to 81.6.
      expect(series.changeOver(30, now), closeTo(-0.8, 1e-9));
      final waistSeries = (await measurements.watchSeries(pid, waist).first)!;
      expect(waistSeries.entries.single.value, 88);
    });

    test('entries can be corrected and deleted', () async {
      final weight = (await measurements.watchAll(pid).first).first.type.id;
      await measurements.logMany(pid, {weight: 80});
      var entry =
          (await measurements.watchSeries(pid, weight).first)!.entries.single;
      await measurements.update(entry.id, value: 79.5);
      entry =
          (await measurements.watchSeries(pid, weight).first)!.entries.single;
      expect(entry.value, 79.5);
      await measurements.delete(entry.id);
      expect(
        (await measurements.watchSeries(pid, weight).first)!.entries,
        isEmpty,
      );
    });

    test('custom types can be added, reordered and deleted', () async {
      final id = await measurements.addType(pid, name: ' Forearm ', unit: 'cm');
      var all = await measurements.watchAll(pid).first;
      expect(all.last.type.name, 'Forearm');

      await measurements.reorderTypes([
        id,
        for (final s in all)
          if (s.type.id != id) s.type.id,
      ]);
      all = await measurements.watchAll(pid).first;
      expect(all.first.type.name, 'Forearm');

      await measurements.logMany(pid, {id: 30});
      await measurements.deleteType(id);
      all = await measurements.watchAll(pid).first;
      expect(all.any((s) => s.type.name == 'Forearm'), isFalse);
      expect(await db.select(db.measurements).get(), isEmpty);
    });
  });

  group('strength', () {
    test('estimated one-rep max', () {
      expect(estimateOneRepMax(100, 1), 100);
      expect(estimateOneRepMax(100, 5), closeTo(116.67, 0.01));
      expect(estimateOneRepMax(null, 5), isNull);
      expect(estimateOneRepMax(60, 0), isNull);
    });

    Future<void> workout(String name, List<(double?, int?)> sets) async {
      final id = await sessions.start(profileId: pid, name: 'W');
      final ex = await exercise(name);
      await sessions.addExercises(id, [ex]);
      final entry = (await sessions.loadWorkout(id))!.exercises.single.entry;
      for (final (i, (kg, reps)) in sets.indexed) {
        await sessions.logSet(
          entry: entry,
          setNumber: i + 1,
          weightKg: kg,
          reps: reps,
        );
      }
      await sessions.finish(id);
      now = now.add(const Duration(days: 3));
    }

    test('history per exercise from finished workouts only', () async {
      await workout('Bench Press', [(60, 10), (70, 5), (70, 6)]);
      await workout('Bench Press', [(75, 5)]);
      await workout('Pull-up', [(null, 8), (null, 10)]);
      // An unfinished workout doesn't count.
      final open = await sessions.start(profileId: pid, name: 'Open');
      await sessions.addExercises(open, [await exercise('Bench Press')]);
      final entry = (await sessions.loadWorkout(open))!.exercises.single.entry;
      await sessions.logSet(entry: entry, setNumber: 1, weightKg: 200, reps: 1);

      final trends = await strength.watchTrends(pid).first;
      expect(
        [for (final t in trends) t.exercise.name],
        ['Pull-up', 'Bench Press'],
      );

      final bench = trends.last;
      expect(bench.history, hasLength(2));
      final first = bench.history.first;
      expect(first.sets, 3);
      expect(first.bestWeightKg, 70);
      expect(first.repsAtBestWeight, 6);
      expect(first.volumeKg, 600 + 350 + 420);
      expect(first.bestE1rm, closeTo(70 * (1 + 6 / 30), 1e-9));
      expect(
        bench.changeOver(30, now),
        closeTo(75 * (1 + 5 / 30) / 84 - 1, 1e-9),
      );

      final pullUps = trends.first;
      expect(pullUps.history.single.bestE1rm, isNull);
      expect(pullUps.history.single.maxReps, 10);
      expect(pullUps.points.single.$2, 10);
    });

    test('records and recent record list', () async {
      await workout('Bench Press', [(80, 5)]);
      await workout('Bench Press', [(85, 3), (80, 8)]);
      await workout('Bench Press', [(82.5, 5)]);
      await workout('Back Squat', [(100, 5)]);

      final trends = await strength.watchTrends(pid).first;
      final bench = trends.firstWhere((t) => t.exercise.name == 'Bench Press');
      final r = ExerciseRecords.from(bench.history);
      expect(r.heaviest!.value, 85);
      expect(r.repsAtHeaviest, 3);
      expect(r.bestE1rm!.value, closeTo(80 * (1 + 8 / 30), 1e-9));
      expect(r.mostVolume!.value, 85 * 3 + 80 * 8);
      expect(r.mostReps!.value, 8);

      // The squat has only one workout, so no record yet.
      final recent = recentRecords(trends);
      expect(recent.single.trend.exercise.name, 'Bench Press');
      expect(recent.single.best.value, 85);
    });
  });
}
