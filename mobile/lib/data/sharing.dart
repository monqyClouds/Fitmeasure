import 'package:drift/drift.dart';

import '../domain/enums.dart';
import 'db/database.dart';
import 'repos/plan_repo.dart';

/// An exercise or plan as shared: a snapshot with its video links (never
/// files from the phone), the same shape the server keeps
/// (server/internal/shares).
class SharedVideo {
  const SharedVideo(this.url, {this.title});
  final String url;
  final String? title;

  Map<String, Object?> toJson() => {'url': url, 'title': ?title};
  factory SharedVideo.fromJson(Map<String, Object?> j) =>
      SharedVideo(j['url']! as String, title: j['title'] as String?);
}

class SharedExercise {
  const SharedExercise({
    required this.name,
    required this.muscle,
    required this.equipment,
    required this.tracking,
    this.notes,
    this.videos = const [],
  });

  final String name;
  final MuscleGroup muscle;
  final Equipment equipment;
  final TrackingType tracking;
  final String? notes;
  final List<SharedVideo> videos;

  Map<String, Object?> toJson() => {
    'name': name,
    'muscle': muscle.name,
    'equipment': equipment.name,
    'tracking': tracking.name,
    'notes': ?notes,
    if (videos.isNotEmpty) 'videos': [for (final v in videos) v.toJson()],
  };

  factory SharedExercise.fromJson(Map<String, Object?> j) => SharedExercise(
    name: j['name']! as String,
    muscle: _byName(MuscleGroup.values, j['muscle'], MuscleGroup.fullBody),
    equipment: _byName(Equipment.values, j['equipment'], Equipment.other),
    tracking: _byName(TrackingType.values, j['tracking'], TrackingType.reps),
    notes: j['notes'] as String?,
    videos: [
      for (final v in (j['videos'] as List?) ?? const [])
        SharedVideo.fromJson((v as Map).cast()),
    ],
  );
}

class SharedItem {
  const SharedItem({
    required this.exercise,
    required this.sets,
    this.reps,
    this.weightKg,
    this.durationSec,
    this.distanceKm,
    this.restSec,
  });

  final SharedExercise exercise;
  final int sets;
  final int? reps;
  final double? weightKg;
  final int? durationSec;
  final double? distanceKm;
  final int? restSec;

  Map<String, Object?> toJson() => {
    'exercise': exercise.toJson(),
    'sets': sets,
    'reps': ?reps,
    'weightKg': ?weightKg,
    'durationSec': ?durationSec,
    'distanceKm': ?distanceKm,
    'restSec': ?restSec,
  };

  factory SharedItem.fromJson(Map<String, Object?> j) => SharedItem(
    exercise: SharedExercise.fromJson((j['exercise']! as Map).cast()),
    sets: (j['sets'] as num?)?.toInt() ?? 3,
    reps: (j['reps'] as num?)?.toInt(),
    weightKg: (j['weightKg'] as num?)?.toDouble(),
    durationSec: (j['durationSec'] as num?)?.toInt(),
    distanceKm: (j['distanceKm'] as num?)?.toDouble(),
    restSec: (j['restSec'] as num?)?.toInt(),
  );
}

class SharedDay {
  const SharedDay({required this.name, this.weekday, this.items = const []});
  final String name;
  final int? weekday;
  final List<SharedItem> items;

  Map<String, Object?> toJson() => {
    'name': name,
    'weekday': ?weekday,
    'items': [for (final i in items) i.toJson()],
  };

  factory SharedDay.fromJson(Map<String, Object?> j) => SharedDay(
    name: j['name'] as String? ?? 'Day',
    weekday: (j['weekday'] as num?)?.toInt(),
    items: [
      for (final i in (j['items'] as List?) ?? const [])
        SharedItem.fromJson((i as Map).cast()),
    ],
  );
}

class SharedPlan {
  const SharedPlan({
    required this.name,
    required this.schedule,
    required this.days,
  });

  final String name;
  final PlanSchedule schedule;
  final List<SharedDay> days;

  Map<String, Object?> toJson() => {
    'name': name,
    'schedule': schedule.name,
    'days': [for (final d in days) d.toJson()],
  };

  factory SharedPlan.fromJson(Map<String, Object?> j) => SharedPlan(
    name: j['name']! as String,
    schedule: _byName(
      PlanSchedule.values,
      j['schedule'],
      PlanSchedule.rotation,
    ),
    days: [
      for (final d in (j['days'] as List?) ?? const [])
        SharedDay.fromJson((d as Map).cast()),
    ],
  );
}

/// One exercise, or a plan.
class ShareContent {
  const ShareContent.exercise(SharedExercise this.exercise) : plan = null;
  const ShareContent.plan(SharedPlan this.plan) : exercise = null;

  final SharedExercise? exercise;
  final SharedPlan? plan;

  String get title => exercise?.name ?? plan!.name;

  Map<String, Object?> toJson() => {
    'v': 1,
    if (exercise != null) ...{
      'kind': 'exercise',
      'exercise': exercise!.toJson(),
    } else ...{
      'kind': 'plan',
      'plan': plan!.toJson(),
    },
  };

  /// Reads a share from the server, or null if it isn't one this app
  /// understands.
  static ShareContent? fromJson(Map<String, Object?> j) {
    try {
      return switch (j['kind']) {
        'exercise' => ShareContent.exercise(
          SharedExercise.fromJson((j['exercise']! as Map).cast()),
        ),
        'plan' => ShareContent.plan(
          SharedPlan.fromJson((j['plan']! as Map).cast()),
        ),
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// Turns the profile's exercises and plans into shares, and shares into
/// exercises and plans.
class Sharing {
  Sharing(this._db, this._plans);
  final AppDatabase _db;
  final PlanRepo _plans;

  Future<List<SharedVideo>> _videos(int exerciseId, int profileId) async {
    final links =
        await (_db.select(_db.exerciseMedia)
              ..where(
                (m) =>
                    m.exerciseId.equals(exerciseId) &
                    m.profileId.equals(profileId) &
                    m.kind.equalsValue(MediaKind.link),
              )
              ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
            .get();
    return [for (final l in links) SharedVideo(l.uri, title: l.label)];
  }

  Future<SharedExercise> _exercise(Exercise e, int profileId) async =>
      SharedExercise(
        name: e.name,
        muscle: e.muscle,
        equipment: e.equipment,
        tracking: e.tracking,
        notes: e.notes,
        videos: await _videos(e.id, profileId),
      );

  /// [e] as a share, with the profile's video links for it.
  Future<ShareContent> exercise(Exercise e, int profileId) async =>
      ShareContent.exercise(await _exercise(e, profileId));

  /// Whether the profile has photos or videos of [exerciseId] from the
  /// phone, which a share leaves out.
  Future<bool> hasOwnFiles(int exerciseId, int profileId) async =>
      (await (_db.select(_db.exerciseMedia)..where(
                (m) =>
                    m.exerciseId.equals(exerciseId) &
                    m.profileId.equals(profileId) &
                    m.kind.equalsValue(MediaKind.link).not(),
              ))
              .get())
          .isNotEmpty;

  /// The plan as a share: its days, targets, and each exercise with its
  /// video links.
  Future<ShareContent> plan(Plan plan, List<PlanDayDetail> days) async =>
      ShareContent.plan(
        SharedPlan(
          name: plan.name,
          schedule: plan.schedule,
          days: [
            for (final d in days)
              SharedDay(
                name: d.day.name,
                weekday: d.day.weekday,
                items: [
                  for (final i in d.items)
                    SharedItem(
                      exercise: await _exercise(i.exercise, plan.profileId),
                      sets: i.item.targetSets,
                      reps: i.item.targetReps,
                      weightKg: i.item.targetWeightKg,
                      durationSec: i.item.targetDurationSec,
                      distanceKm: i.item.targetDistanceKm,
                      restSec: i.item.restSec,
                    ),
                ],
              ),
          ],
        ),
      );

  /// Adds a shared exercise to the profile's library: an exercise with the
  /// same name (built in or theirs) gets the videos it doesn't already
  /// have; otherwise it's created. Returns the exercise's ID.
  Future<int> importExercise(SharedExercise s, int profileId) =>
      _db.transaction(() async {
        final name = s.name.trim();
        final existing =
            await (_db.select(_db.exercises)
                  ..where(
                    (e) =>
                        e.name.lower().equals(name.toLowerCase()) &
                        (e.profileId.isNull() | e.profileId.equals(profileId)),
                  )
                  ..orderBy([(e) => OrderingTerm.desc(e.profileId)])
                  ..limit(1))
                .getSingleOrNull();
        final id =
            existing?.id ??
            await _db
                .into(_db.exercises)
                .insert(
                  ExercisesCompanion.insert(
                    profileId: Value(profileId),
                    name: name,
                    muscle: s.muscle,
                    equipment: s.equipment,
                    tracking: s.tracking,
                    notes: Value(s.notes),
                  ),
                );
        final have = {for (final v in await _videos(id, profileId)) v.url};
        for (final v in s.videos) {
          if (have.contains(v.url)) continue;
          await _db
              .into(_db.exerciseMedia)
              .insert(
                ExerciseMediaCompanion.insert(
                  profileId: profileId,
                  exerciseId: id,
                  kind: MediaKind.link,
                  uri: v.url,
                  label: Value(v.title),
                ),
              );
        }
        return id;
      });

  /// Adds a shared plan to the profile, as their active plan. Its
  /// exercises are matched to the library by name, or added. Returns the
  /// plan's ID.
  Future<int> importPlan(SharedPlan s, int profileId) =>
      _db.transaction(() async {
        final planId = await _plans.createPlan(
          profileId: profileId,
          name: s.name,
          schedule: s.schedule,
        );
        for (final d in s.days) {
          final dayId = await _plans.addDay(
            planId: planId,
            name: d.name,
            weekday: s.schedule == PlanSchedule.weekly ? d.weekday : null,
          );
          for (final (pos, i) in d.items.indexed) {
            final exerciseId = await importExercise(i.exercise, profileId);
            await _db
                .into(_db.planItems)
                .insert(
                  PlanItemsCompanion.insert(
                    planDayId: dayId,
                    exerciseId: exerciseId,
                    position: pos,
                    targetSets: i.sets,
                    targetReps: Value(i.reps),
                    targetWeightKg: Value(i.weightKg),
                    targetDurationSec: Value(i.durationSec),
                    targetDistanceKm: Value(i.distanceKm),
                    restSec: Value(i.restSec),
                  ),
                );
          }
        }
        return planId;
      });
}
