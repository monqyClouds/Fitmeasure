import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/plan_repo.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/repos/session_repo.dart';
import 'package:fitmeasure/data/seed/exercise_seed.dart';
import 'package:fitmeasure/data/seed/plan_templates.dart';
import 'package:fitmeasure/domain/enums.dart';
import 'package:fitmeasure/domain/units.dart';
import 'package:fitmeasure/features/progress/progress_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PlanRepo plans;
  late SessionRepo sessions;
  late DateTime now;
  late int pid;

  Future<Exercise> exercise(String name) =>
      (db.select(db.exercises)..where((e) => e.name.equals(name))).getSingle();

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    plans = PlanRepo(db);
    now = DateTime(2026, 9, 28, 18); // a Monday
    sessions = SessionRepo(db, clock: () => now);
    pid = await ProfileRepo(db).create(name: 'Ada', color: 1);
  });

  tearDown(() => db.close());

  group('plans', () {
    test('every template exercise is in the built-in library', () {
      final names = {for (final e in seedExercises) e.$1};
      for (final tpl in planTemplates) {
        for (final (_, _, exercises) in tpl.days) {
          for (final n in exercises) {
            expect(names, contains(n), reason: '${tpl.name}: $n');
          }
        }
      }
    });

    test('a template becomes a plan with days and targets', () async {
      final tpl = planTemplates.first;
      final id = await plans.createFromTemplate(
        profileId: pid,
        template: tpl,
        cycle: CycleType.strength,
      );
      final days = await plans.watchDays(id).first;
      expect(
        [for (final d in days) d.day.name],
        [for (final d in tpl.days) d.$1],
      );
      expect(days.first.items, hasLength(tpl.days.first.$3.length));
      final first = days.first.items.first.item;
      expect(first.targetSets, CycleType.strength.sets);
      expect(first.targetReps, CycleType.strength.reps);
      expect(first.restSec, CycleType.strength.restSec);
    });

    test('only the newest or chosen plan is active', () async {
      final a = await plans.createPlan(
        profileId: pid,
        name: 'A',
        schedule: PlanSchedule.weekly,
      );
      await plans.createPlan(
        profileId: pid,
        name: 'B',
        schedule: PlanSchedule.rotation,
      );
      var list = await plans.watchPlans(pid).first;
      expect(
        [for (final p in list) (p.plan.name, p.plan.active)],
        [('B', true), ('A', false)],
      );
      await plans.setActive(list.last.plan);
      list = await plans.watchPlans(pid).first;
      expect(list.first.plan.id, a);
      expect(list.where((p) => p.plan.active), hasLength(1));
    });

    test('timed exercises get a duration target, not reps', () async {
      final id = await plans.createPlan(
        profileId: pid,
        name: 'Core',
        schedule: PlanSchedule.rotation,
      );
      final day = await plans.addDay(planId: id, name: 'Core');
      await plans.addItems(day, [await exercise('Plank')]);
      final item = (await plans.watchDays(id).first).single.items.single.item;
      expect(item.targetReps, isNull);
      expect(item.targetDurationSec, 60);
    });

    test('reordering items and days sticks', () async {
      final id = await plans.createPlan(
        profileId: pid,
        name: 'P',
        schedule: PlanSchedule.rotation,
      );
      final d1 = await plans.addDay(planId: id, name: 'One');
      final d2 = await plans.addDay(planId: id, name: 'Two');
      await plans.addItems(d1, [
        await exercise('Bench Press'),
        await exercise('Pull-up'),
      ]);
      await plans.reorderDays([d2, d1]);
      var days = await plans.watchDays(id).first;
      expect([for (final d in days) d.day.name], ['Two', 'One']);
      final items = days.last.items;
      await plans.reorderItems([items.last.item.id, items.first.item.id]);
      days = await plans.watchDays(id).first;
      expect(
        [for (final i in days.last.items) i.exercise.name],
        ['Pull-up', 'Bench Press'],
      );
    });
  });

  group('today', () {
    Future<int> weekly() async {
      final id = await plans.createPlan(
        profileId: pid,
        name: 'Week',
        schedule: PlanSchedule.weekly,
      );
      await plans.addDay(planId: id, name: 'Push', weekday: DateTime.monday);
      await plans.addDay(planId: id, name: 'Pull', weekday: DateTime.thursday);
      return id;
    }

    test('is null without an active plan', () async {
      expect(await plans.todayFor(pid, now), isNull);
    });

    test('weekly: the day for this weekday, or the next one', () async {
      await weekly();
      final monday = await plans.todayFor(pid, now);
      expect(monday!.today!.day.name, 'Push');
      final tuesday = await plans.todayFor(pid, DateTime(2026, 9, 29));
      expect(tuesday!.today, isNull);
      expect(tuesday.next!.day.name, 'Pull');
      final friday = await plans.todayFor(pid, DateTime(2026, 10, 2));
      expect(friday!.next!.day.name, 'Push');
    });

    test('weekly: marked done once trained today', () async {
      await weekly();
      final day = (await plans.todayFor(pid, now))!.today!;
      expect((await plans.todayFor(pid, now))!.doneToday, isFalse);
      final s = await sessions.start(
        profileId: pid,
        name: 'Push',
        planDayId: day.day.id,
      );
      expect((await plans.todayFor(pid, now))!.doneToday, isFalse);
      await sessions.finish(s);
      expect((await plans.todayFor(pid, now))!.doneToday, isTrue);
    });

    test('rotation: moves on after each finished day', () async {
      final id = await plans.createFromTemplate(
        profileId: pid,
        template: planTemplates.first, // Push / Pull / Legs
      );
      final days = await plans.watchDays(id).first;
      expect((await plans.todayFor(pid, now))!.today!.day.name, 'Push');

      // Trained Push yesterday: today is Pull.
      now = DateTime(2026, 9, 27, 18);
      await sessions.finish(
        await sessions.start(
          profileId: pid,
          name: 'Push',
          planDayId: days[0].day.id,
        ),
      );
      now = DateTime(2026, 9, 28, 18);
      var today = (await plans.todayFor(pid, now))!;
      expect(today.today!.day.name, 'Pull');
      expect(today.doneToday, isFalse);

      // After training Pull today it stays on Pull, marked done.
      await sessions.finish(
        await sessions.start(
          profileId: pid,
          name: 'Pull',
          planDayId: days[1].day.id,
        ),
      );
      today = (await plans.todayFor(pid, now))!;
      expect(today.today!.day.name, 'Pull');
      expect(today.doneToday, isTrue);

      // Tomorrow Legs, then it wraps round to Push.
      expect(
        (await plans.todayFor(pid, DateTime(2026, 9, 29)))!.today!.day.name,
        'Legs',
      );
      now = DateTime(2026, 9, 29, 18);
      await sessions.finish(
        await sessions.start(
          profileId: pid,
          name: 'Legs',
          planDayId: days[2].day.id,
        ),
      );
      expect(
        (await plans.todayFor(pid, DateTime(2026, 9, 30)))!.today!.day.name,
        'Push',
      );
    });
  });

  group('workouts', () {
    Future<(int, int)> planned() async {
      final plan = await plans.createPlan(
        profileId: pid,
        name: 'P',
        schedule: PlanSchedule.rotation,
      );
      final day = await plans.addDay(planId: plan, name: 'Push');
      await plans.addItems(day, [
        await exercise('Bench Press'),
        await exercise('Overhead Press'),
      ], cycle: CycleType.bulk);
      final session = await sessions.start(
        profileId: pid,
        name: 'Push',
        planDayId: day,
      );
      return (day, session);
    }

    test('starting from a plan day copies its exercises', () async {
      final (_, id) = await planned();
      final w = (await sessions.loadWorkout(id))!;
      expect(
        [for (final e in w.exercises) e.exercise.name],
        ['Bench Press', 'Overhead Press'],
      );
      expect(w.exercises.first.entry.targetSets, CycleType.bulk.sets);
      expect(w.remainingSets, CycleType.bulk.sets * 2);
      expect(await sessions.watchActive(pid).first, isNotNull);
    });

    test('logging sets records rest, replaces and unlogs', () async {
      final (_, id) = await planned();
      var w = (await sessions.loadWorkout(id))!;
      final bench = w.exercises.first.entry;

      await sessions.logSet(entry: bench, setNumber: 1, reps: 10, weightKg: 60);
      now = now.add(const Duration(seconds: 95));
      await sessions.logSet(entry: bench, setNumber: 2, reps: 9, weightKg: 60);
      // Logging set 2 again corrects it, keeping when it was done.
      now = now.add(const Duration(seconds: 5));
      await sessions.logSet(
        entry: bench,
        setNumber: 2,
        reps: 10,
        weightKg: 62.5,
      );

      w = (await sessions.loadWorkout(id))!;
      final sets = w.exercises.first.sets;
      expect([for (final s in sets) (s.setNumber, s.reps)], [(1, 10), (2, 10)]);
      expect(sets.first.restSec, isNull);
      expect(sets.first.targetReps, CycleType.bulk.reps);
      expect(sets.last.restSec, 95);
      expect(sets.last.weightKg, 62.5);
      expect(w.loggedSets, 2);
      expect(w.volumeKg, 60 * 10 + 62.5 * 10);

      await sessions.unlogSet(sets.first.id);
      w = (await sessions.loadWorkout(id))!;
      expect(w.exercises.first.logged(1), isNull);
      expect(w.exercises.first.rowCount, CycleType.bulk.sets);
    });

    test('rest over half an hour is not recorded', () async {
      final (_, id) = await planned();
      final bench = (await sessions.loadWorkout(id))!.exercises.first.entry;
      await sessions.logSet(entry: bench, setNumber: 1, reps: 5);
      now = now.add(const Duration(minutes: 45));
      await sessions.logSet(entry: bench, setNumber: 2, reps: 5);
      final sets = (await sessions.loadWorkout(id))!.exercises.first.sets;
      expect(sets.last.restSec, isNull);
    });

    test('exercises can be added and removed mid-workout', () async {
      final id = await sessions.start(profileId: pid, name: 'Workout');
      final squat = await exercise('Back Squat');
      await sessions.addExercises(id, [squat, await exercise('Plank')]);
      await sessions.addExercises(id, [squat]); // already there
      var w = (await sessions.loadWorkout(id))!;
      expect(w.exercises, hasLength(2));

      await sessions.logSet(
        entry: w.exercises.first.entry,
        setNumber: 1,
        reps: 5,
        weightKg: 100,
      );
      await sessions.removeExercise(w.exercises.first.entry);
      w = (await sessions.loadWorkout(id))!;
      expect([for (final e in w.exercises) e.exercise.name], ['Plank']);
      expect(await db.select(db.setLogs).get(), isEmpty);
    });

    test('finished workouts show in history with totals', () async {
      final (_, id) = await planned();
      final bench = (await sessions.loadWorkout(id))!.exercises.first.entry;
      await sessions.logSet(entry: bench, setNumber: 1, reps: 10, weightKg: 50);
      await sessions.logSet(entry: bench, setNumber: 2, reps: 8, weightKg: 50);
      expect(await sessions.watchRecent(pid).first, isEmpty);

      now = now.add(const Duration(minutes: 40));
      await sessions.finish(id);
      final recent = await sessions.watchRecent(pid).first;
      expect(recent.single.sets, 2);
      expect(recent.single.volumeKg, 900);
      expect(recent.single.duration, const Duration(minutes: 40));
      expect(await sessions.watchActive(pid).first, isNull);
    });

    test(
      'last sets and personal bests compare with earlier workouts',
      () async {
        final bench = await exercise('Bench Press');
        Future<int> workout(double kg) async {
          final id = await sessions.start(profileId: pid, name: 'W');
          await sessions.addExercises(id, [bench]);
          final entry = (await sessions.loadWorkout(id))!.exercises.first.entry;
          await sessions.logSet(
            entry: entry,
            setNumber: 1,
            reps: 5,
            weightKg: kg,
          );
          await sessions.finish(id);
          now = now.add(const Duration(days: 2));
          return id;
        }

        final first = await workout(80);
        expect(await sessions.weightRecords(first), isEmpty);
        final second = await workout(85);
        expect(await sessions.weightRecords(second), {bench.id: 85});
        final third = await workout(82.5);
        expect(await sessions.weightRecords(third), isEmpty);

        final last = await sessions.lastSets(
          profileId: pid,
          exerciseId: bench.id,
          excludeSessionId: third,
        );
        expect(last.single.weightKg, 85);
      },
    );

    test('deleting a workout removes its sets', () async {
      final (_, id) = await planned();
      final bench = (await sessions.loadWorkout(id))!.exercises.first.entry;
      await sessions.logSet(entry: bench, setNumber: 1, reps: 1);
      await sessions.delete(id);
      expect(await db.select(db.setLogs).get(), isEmpty);
      expect(await db.select(db.sessionExercises).get(), isEmpty);
    });
  });

  test('upgrading a version 1 database adds the workout table', () async {
    // Opens a second database alongside the one from setUp, on purpose.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
    );
    final dir = await Directory.systemTemp.createTemp('fitmeasure_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Make a database as version 1 left it: no session_exercises table.
    var old = AppDatabase(NativeDatabase(file));
    await ProfileRepo(old).create(name: 'Kept', color: 1);
    await old.customStatement('DROP TABLE session_exercises');
    await old.customStatement('PRAGMA user_version = 1');
    await old.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(await upgraded.select(upgraded.sessionExercises).get(), isEmpty);
    expect(
      (await upgraded.select(upgraded.profiles).get()).single.name,
      'Kept',
    );
  });

  test('week streak counts back from this week or last', () {
    final wed = DateTime(2026, 9, 30);
    int streak(List<DateTime> d) => ProgressScreen.weekStreak(d, wed);
    expect(streak([]), 0);
    // This week and the two before.
    expect(
      streak([
        DateTime(2026, 9, 28),
        DateTime(2026, 9, 22),
        DateTime(2026, 9, 14),
      ]),
      3,
    );
    // Nothing yet this week doesn't break a streak that ran to last week.
    expect(streak([DateTime(2026, 9, 25), DateTime(2026, 9, 17)]), 2);
    // A gap ends it.
    expect(streak([DateTime(2026, 9, 29), DateTime(2026, 9, 10)]), 1);
  });

  test('upgrading to version 3 makes media paths relative', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
    );
    final dir = await Directory.systemTemp.createTemp('fitmeasure_v3');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    var old = AppDatabase(NativeDatabase(file));
    final p = await ProfileRepo(old).create(name: 'Ada', color: 1);
    final bench = await (old.select(old.exercises)..limit(1)).getSingle();
    for (final (kind, uri) in [
      (
        'image',
        '/data/user/0/com.fitmeasure.fitmeasure/app_flutter/media/$p/1.jpg',
      ),
      ('link', 'https://youtu.be/media/abc'),
    ]) {
      await old.customStatement(
        'INSERT INTO exercise_media (profile_id, exercise_id, kind, uri) '
        'VALUES (?, ?, ?, ?)',
        [p, bench.id, kind, uri],
      );
    }
    await old.customStatement('PRAGMA user_version = 2');
    await old.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final uris = [
      for (final m in await upgraded.select(upgraded.exerciseMedia).get())
        m.uri,
    ];
    expect(uris, ['media/$p/1.jpg', 'https://youtu.be/media/abc']);
  });

  group('units', () {
    test('numbers and durations format and parse', () {
      expect(formatNumber(60), '60');
      expect(formatNumber(62.5), '62.5');
      expect(formatDuration(75), '1:15');
      expect(formatDuration(3725), '1:02:05');
      expect(parseDuration('1:30'), 90);
      expect(parseDuration('45'), 45);
      expect(parseDuration('1:02:05'), 3725);
      expect(parseDuration('x'), isNull);
      expect(parseDecimal('62,5'), 62.5);
    });

    test('targets and sets read naturally', () {
      expect(
        describeTargets(TrackingType.reps, sets: 4, reps: 10, weightKg: 60),
        '4 × 10 · 60 kg',
      );
      expect(
        describeTargets(TrackingType.time, sets: 3, durationSec: 60),
        '3 × 1:00',
      );
      expect(
        describeSet(TrackingType.reps, reps: 8, weightKg: 70),
        '70 kg × 8',
      );
      expect(describeSet(TrackingType.reps, reps: 12), '12 reps');
      expect(
        describeSet(TrackingType.distance, distanceKm: 5, durationSec: 1800),
        '5 km · 30:00',
      );
    });
  });
}
