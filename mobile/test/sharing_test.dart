import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/exercise_repo.dart';
import 'package:fitmeasure/data/repos/plan_repo.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/sharing.dart';
import 'package:fitmeasure/domain/enums.dart';
import 'package:fitmeasure/features/share/shares_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Sharing sharing;
  late ExerciseRepo exercises;
  late PlanRepo plans;
  late int ada, bo;

  Future<Exercise> named(String name, {int? profileId}) =>
      (db.select(db.exercises)..where(
            (e) =>
                e.name.equals(name) &
                (profileId == null
                    ? e.profileId.isNull()
                    : e.profileId.equals(profileId)),
          ))
          .getSingle();

  Future<List<String>> links(int exerciseId, int profileId) async => [
    for (final m in await exercises.watchMedia(exerciseId, profileId).first)
      if (m.kind == MediaKind.link) m.uri,
  ];

  /// Through JSON, as it goes to the server and back.
  ShareContent roundTrip(ShareContent s) => ShareContent.fromJson(
    (jsonDecode(jsonEncode(s.toJson())) as Map).cast(),
  )!;

  setUp(() async {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    plans = PlanRepo(db);
    sharing = Sharing(db, plans);
    exercises = ExerciseRepo(db);
    ada = await ProfileRepo(db).create(name: 'Ada', color: 1);
    bo = await ProfileRepo(db).create(name: 'Bo', color: 2);
  });
  tearDown(() => db.close());

  test(
    'an exercise travels with its links, and lands on a match by name',
    () async {
      final plank = await named('Plank');
      await exercises.addLink(
        exerciseId: plank.id,
        profileId: ada,
        url: 'https://youtu.be/dQw4w9WgXcQ',
        label: 'Perfect plank',
      );
      await exercises.addLink(
        exerciseId: plank.id,
        profileId: bo,
        url: 'https://example.com/bo-only',
      );

      final share = roundTrip(await sharing.exercise(plank, ada));
      expect(share.exercise!.videos.map((v) => (v.url, v.title)), [
        ('https://youtu.be/dQw4w9WgXcQ', 'Perfect plank'),
      ]);
      expect(share.exercise!.tracking, TrackingType.time);

      // Bo has the built-in Plank: the video joins it, once.
      final id = await sharing.importExercise(share.exercise!, bo);
      expect(id, plank.id);
      await sharing.importExercise(share.exercise!, bo);
      expect(await links(plank.id, bo), [
        'https://example.com/bo-only',
        'https://youtu.be/dQw4w9WgXcQ',
      ]);
    },
  );

  test(
    'an exercise nobody has is created, in the importer\'s library',
    () async {
      final mine = await exercises.saveCustom(
        profileId: ada,
        name: 'Banded Pull-apart',
        muscle: MuscleGroup.back,
        equipment: Equipment.other,
        tracking: TrackingType.reps,
        notes: 'Slow on the way back',
      );
      final share = roundTrip(
        await sharing.exercise(
          await named('Banded Pull-apart', profileId: ada),
          ada,
        ),
      );
      final id = await sharing.importExercise(share.exercise!, bo);
      expect(id, isNot(mine));
      final created = await named('Banded Pull-apart', profileId: bo);
      expect(created.muscle, MuscleGroup.back);
      expect(created.notes, 'Slow on the way back');
    },
  );

  test(
    'a plan travels with its days and targets, and becomes active',
    () async {
      final planId = await plans.createPlan(
        profileId: ada,
        name: 'Push Pull',
        schedule: PlanSchedule.weekly,
      );
      final push = await plans.addDay(planId: planId, name: 'Push', weekday: 1);
      await plans.addItems(push, [
        await named('Bench Press'),
        await named('Plank'),
      ]);
      final day = (await plans.watchDays(planId).first).single;
      await plans.updateItem(day.items.first.item.id, (
        sets: 4,
        reps: 8,
        weightKg: 62.5,
        durationSec: null,
        distanceKm: null,
        restSec: 90,
      ));
      final plan = (await plans.watchPlans(ada).first).single;

      final share = roundTrip(
        await sharing.plan(plan.plan, await plans.watchDays(planId).first),
      );
      final imported = await sharing.importPlan(share.plan!, bo);

      final bos = (await plans.watchPlans(bo).first).single;
      expect(bos.plan.id, imported);
      expect(bos.plan.active, isTrue);
      expect(bos.plan.schedule, PlanSchedule.weekly);
      final d = bos.days.single;
      expect((d.day.name, d.day.weekday), ('Push', 1));
      expect(
        [for (final i in d.items) i.exercise.name],
        ['Bench Press', 'Plank'],
      );
      final bench = d.items.first.item;
      expect(
        (
          bench.targetSets,
          bench.targetReps,
          bench.targetWeightKg,
          bench.restSec,
        ),
        (4, 8, 62.5, 90),
      );
    },
  );

  test('share links', () {
    expect(
      shareIdFromLink(Uri.parse('https://live.somto.si/s/k7f3qz2m')),
      'k7f3qz2m',
    );
    expect(shareIdFromLink(Uri.parse('https://live.somto.si/s/short')), isNull);
    expect(
      shareIdFromLink(Uri.parse('https://live.somto.si/r/k7f3qz')),
      isNull,
    );
    expect(ShareContent.fromJson({'kind': 'workout'}), isNull);
  });
}
