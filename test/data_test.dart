import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/cycle_repo.dart';
import 'package:fitmeasure/data/repos/exercise_repo.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/seed/exercise_seed.dart';
import 'package:fitmeasure/domain/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late ProfileRepo profiles;
  late CycleRepo cycles;
  late ExerciseRepo exercises;

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    tmp = await Directory.systemTemp.createTemp('fitmeasure_test');
    profiles = ProfileRepo(db, mediaRoot: () async => tmp);
    cycles = CycleRepo(db);
    exercises = ExerciseRepo(db, mediaRoot: () async => tmp);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('built-in exercises are seeded once with unique names', () async {
    final all = await db.select(db.exercises).get();
    expect(all, hasLength(seedExercises.length));
    expect(all.map((e) => e.name).toSet(), hasLength(all.length));
    expect(all.every((e) => e.profileId == null), isTrue);
  });

  test('creating a profile seeds its measurement types', () async {
    final id = await profiles.create(name: '  Ada ', color: 0xFF00FF00);
    final p = await profiles.watch(id).first;
    expect(p!.name, 'Ada');
    final types = await (db.select(
      db.measurementTypes,
    )..where((t) => t.profileId.equals(id))).get();
    expect(types.map((t) => t.name), contains('Body weight'));
    expect(types.firstWhere((t) => t.name == 'Body weight').unit, 'kg');
    expect(types.firstWhere((t) => t.name == 'Waist').unit, 'cm');
  });

  test('last used profile is remembered and can be cleared', () async {
    final id = await profiles.create(name: 'Ada', color: 1);
    await profiles.setLastUsed(id);
    expect(await profiles.lastUsedId(), id);
    await profiles.setLastUsed(null);
    expect(await profiles.lastUsedId(), isNull);
  });

  test('starting a cycle ends the one still running', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    final first = await cycles.save(
      profileId: pid,
      type: CycleType.routine,
      name: 'Routine',
      startDate: DateTime(2026, 1, 1),
    );
    await cycles.save(
      profileId: pid,
      type: CycleType.bulk,
      name: 'Bulk',
      startDate: DateTime(2026, 3, 1, 15, 30),
      endDate: DateTime(2026, 5, 23),
    );
    final list = await cycles.watchForProfile(pid).first;
    expect(list.first.name, 'Bulk');
    expect(list.first.startDate, DateTime(2026, 3, 1));
    final routine = list.firstWhere((c) => c.id == first);
    expect(routine.endDate, DateTime(2026, 2, 28));
  });

  test('a cycle starting the same day as another is rejected', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    await cycles.save(
      profileId: pid,
      type: CycleType.routine,
      name: 'Routine',
      startDate: DateTime(2026, 3, 1),
    );
    await expectLater(
      cycles.save(
        profileId: pid,
        type: CycleType.bulk,
        name: 'Bulk',
        startDate: DateTime(2026, 3, 1),
        endDate: DateTime(2026, 5, 23),
      ),
      throwsA(isA<CycleOverlapException>()),
    );
    final list = await cycles.watchForProfile(pid).first;
    expect(list.single.name, 'Routine');
    expect(list.single.endDate, isNull);
  });

  test('an open-ended cycle before a later one ends the day before', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    await cycles.save(
      profileId: pid,
      type: CycleType.bulk,
      name: 'Bulk',
      startDate: DateTime(2026, 3, 1),
      endDate: DateTime(2026, 5, 23),
    );
    final routine = await cycles.save(
      profileId: pid,
      type: CycleType.routine,
      name: 'Routine',
      startDate: DateTime(2026, 1, 1),
    );
    final list = await cycles.watchForProfile(pid).first;
    expect(
      list.firstWhere((c) => c.id == routine).endDate,
      DateTime(2026, 2, 28),
    );
    expect(
      list.firstWhere((c) => c.name == 'Bulk').endDate,
      DateTime(2026, 5, 23),
    );
  });

  test('a fixed-length cycle running into a later one is rejected', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    await cycles.save(
      profileId: pid,
      type: CycleType.bulk,
      name: 'Bulk',
      startDate: DateTime(2026, 3, 1),
    );
    await expectLater(
      cycles.save(
        profileId: pid,
        type: CycleType.cut,
        name: 'Cut',
        startDate: DateTime(2026, 2, 1),
        endDate: DateTime(2026, 3, 1),
      ),
      throwsA(isA<CycleOverlapException>()),
    );
    // Ending the day before is fine.
    await cycles.save(
      profileId: pid,
      type: CycleType.cut,
      name: 'Cut',
      startDate: DateTime(2026, 2, 1),
      endDate: DateTime(2026, 2, 28),
    );
    expect(await cycles.watchForProfile(pid).first, hasLength(2));
  });

  test('editing a cycle does not conflict with itself', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    final id = await cycles.save(
      profileId: pid,
      type: CycleType.bulk,
      name: 'Bulk',
      startDate: DateTime(2026, 3, 1),
    );
    await cycles.save(
      id: id,
      profileId: pid,
      type: CycleType.strength,
      name: 'Strength',
      startDate: DateTime(2026, 3, 1),
      endDate: DateTime(2026, 4, 25),
    );
    final c = (await cycles.watchForProfile(pid).first).single;
    expect(c.type, CycleType.strength);
    expect(c.endDate, DateTime(2026, 4, 25));
  });

  test('cycle week maths', () async {
    final pid = await profiles.create(name: 'Ada', color: 1);
    await cycles.save(
      profileId: pid,
      type: CycleType.cut,
      name: 'Cut',
      startDate: DateTime(2026, 1, 5),
      endDate: DateTime(2026, 3, 1), // 8 weeks
    );
    final c = (await cycles.watchForProfile(pid).first).single;
    expect(c.totalWeeks, 8);
    expect(c.weekOf(DateTime(2026, 1, 5)), 1);
    expect(c.weekOf(DateTime(2026, 1, 12)), 2);
    expect(c.isActiveOn(DateTime(2026, 3, 1)), isTrue);
    expect(c.isActiveOn(DateTime(2026, 3, 2)), isFalse);
  });

  test('custom exercises are only visible to their profile', () async {
    final a = await profiles.create(name: 'A', color: 1);
    final b = await profiles.create(name: 'B', color: 2);
    await exercises.saveCustom(
      profileId: a,
      name: 'Landmine Press',
      muscle: MuscleGroup.shoulders,
      equipment: Equipment.barbell,
      tracking: TrackingType.reps,
    );
    final libA = await exercises.watchLibrary(a).first;
    final libB = await exercises.watchLibrary(b).first;
    expect(libA, hasLength(seedExercises.length + 1));
    expect(libB, hasLength(seedExercises.length));
    expect(libA.map((e) => e.exercise.name), contains('Landmine Press'));
  });

  test('media files are copied in, counted per profile and deleted', () async {
    final a = await profiles.create(name: 'A', color: 1);
    final b = await profiles.create(name: 'B', color: 2);
    final bench = (await db.select(db.exercises).get()).firstWhere(
      (e) => e.name == 'Bench Press',
    );

    await exercises.addFile(
      exerciseId: bench.id,
      profileId: a,
      fileName: 'Form Check.MP4',
      bytes: Stream.value([1, 2, 3]),
    );
    await exercises.addLink(
      exerciseId: bench.id,
      profileId: a,
      url: 'https://youtu.be/abc',
      label: ' ',
    );

    final media = await exercises.watchMedia(bench.id, a).first;
    expect(media, hasLength(2));
    final video = media.firstWhere((m) => m.kind == MediaKind.video);
    expect(video.label, 'Form Check');
    // Stored relative to the documents folder, which moves on iOS.
    expect(video.uri, startsWith('media/$a/'));
    expect(await File('${tmp.path}/${video.uri}').readAsBytes(), [1, 2, 3]);
    expect(media.firstWhere((m) => m.kind == MediaKind.link).label, isNull);

    int count(List<ExerciseWithMedia> lib) =>
        lib.firstWhere((e) => e.exercise.id == bench.id).mediaCount;
    expect(count(await exercises.watchLibrary(a).first), 2);
    expect(count(await exercises.watchLibrary(b).first), 0);

    await exercises.deleteMedia(video);
    expect(await File('${tmp.path}/${video.uri}').exists(), isFalse);
    expect(await exercises.watchMedia(bench.id, a).first, hasLength(1));
  });

  test('deleting a profile removes its data and media folder', () async {
    final a = await profiles.create(name: 'A', color: 1);
    final bench = (await db.select(db.exercises).get()).first;
    await exercises.addFile(
      exerciseId: bench.id,
      profileId: a,
      fileName: 'x.jpg',
      bytes: Stream.value([9]),
    );
    await cycles.save(
      profileId: a,
      type: CycleType.bulk,
      name: 'Bulk',
      startDate: DateTime(2026, 1, 1),
    );
    await profiles.delete(a);

    expect(await db.select(db.cycles).get(), isEmpty);
    expect(await db.select(db.exerciseMedia).get(), isEmpty);
    expect(await db.select(db.measurementTypes).get(), isEmpty);
    expect(await Directory('${tmp.path}/media/$a').exists(), isFalse);
    // Built-in library is untouched.
    expect(
      await db.select(db.exercises).get(),
      hasLength(seedExercises.length),
    );
  });

  test('media kind is inferred from the file extension', () {
    expect(ExerciseRepo.kindForExtension('.mov'), MediaKind.video);
    expect(ExerciseRepo.kindForExtension('.JPG'), MediaKind.image);
  });
}
