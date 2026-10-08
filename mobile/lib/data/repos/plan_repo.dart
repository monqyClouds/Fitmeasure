import 'package:drift/drift.dart';

import '../../domain/dates.dart';
import '../../domain/enums.dart';
import '../../domain/targets.dart';
import '../db/database.dart';
import '../seed/plan_templates.dart';
import 'live_query.dart';

class PlanItemDetail {
  const PlanItemDetail(this.item, this.exercise);
  final PlanItem item;
  final Exercise exercise;

  Targets get targets => (
    sets: item.targetSets,
    reps: item.targetReps,
    weightKg: item.targetWeightKg,
    durationSec: item.targetDurationSec,
    distanceKm: item.targetDistanceKm,
    restSec: item.restSec,
  );
}

class PlanDayDetail {
  const PlanDayDetail(this.day, this.items);
  final PlanDay day;
  final List<PlanItemDetail> items;

  int get totalSets => items.fold(0, (n, i) => n + i.item.targetSets);

  int get estimatedMinutes => estimateMinutes([
    for (final i in items) (i.exercise.tracking, i.targets),
  ]);

  List<Exercise> get exercises => [for (final i in items) i.exercise];
}

class PlanOverview {
  const PlanOverview(this.plan, this.days);
  final Plan plan;
  final List<PlanDayDetail> days;

  int get exerciseCount => days.fold(0, (n, d) => n + d.items.length);
}

/// What the active plan says about a given day.
class TodayPlan {
  const TodayPlan({
    required this.plan,
    required this.days,
    this.today,
    this.next,
    this.doneToday = false,
  });

  final Plan plan;
  final List<PlanDayDetail> days;

  /// The day to train, or null on a weekly plan's rest day (or an empty plan).
  final PlanDayDetail? today;

  /// On a rest day, the next scheduled day.
  final PlanDayDetail? next;

  /// Whether [today] has already been trained today.
  final bool doneToday;
}

class PlanRepo {
  PlanRepo(this._db);
  final AppDatabase _db;

  // --- Plans ---------------------------------------------------------------

  /// The profile's plans, the active one first.
  Stream<List<PlanOverview>> watchPlans(int profileId) => _db.watchLoad(
    [_db.plans, _db.planDays, _db.planItems, _db.exercises],
    () async {
      final plans =
          await (_db.select(_db.plans)
                ..where((p) => p.profileId.equals(profileId))
                ..orderBy([
                  (p) => OrderingTerm.desc(p.active),
                  (p) => OrderingTerm.desc(p.createdAt),
                ]))
              .get();
      return [for (final p in plans) PlanOverview(p, await _loadDays(p.id))];
    },
  );

  Stream<Plan?> watchPlan(int id) => (_db.select(
    _db.plans,
  )..where((p) => p.id.equals(id))).watchSingleOrNull();

  /// Creates a plan and makes it the active one.
  Future<int> createPlan({
    required int profileId,
    required String name,
    required PlanSchedule schedule,
  }) => _db.transaction(() async {
    await _deactivateAll(profileId);
    return _db
        .into(_db.plans)
        .insert(
          PlansCompanion.insert(
            profileId: profileId,
            name: name.trim(),
            schedule: schedule,
          ),
        );
  });

  /// Creates an active plan from [template], with targets from [cycle].
  Future<int> createFromTemplate({
    required int profileId,
    required PlanTemplate template,
    CycleType? cycle,
  }) => _db.transaction(() async {
    final builtIn = {
      for (final e in await (_db.select(
        _db.exercises,
      )..where((e) => e.profileId.isNull())).get())
        e.name: e,
    };
    final planId = await createPlan(
      profileId: profileId,
      name: template.name,
      schedule: template.schedule,
    );
    for (final (name, weekday, exercises) in template.days) {
      final dayId = await addDay(planId: planId, name: name, weekday: weekday);
      await addItems(dayId, [
        for (final n in exercises) ?builtIn[n],
      ], cycle: cycle);
    }
    return planId;
  });

  Future<void> renamePlan(int id, String name) =>
      (_db.update(_db.plans)..where((p) => p.id.equals(id))).write(
        PlansCompanion(name: Value(name.trim())),
      );

  /// Makes [plan] the one Today follows; only one plan is active at a time.
  Future<void> setActive(Plan plan) => _db.transaction(() async {
    await _deactivateAll(plan.profileId);
    await (_db.update(_db.plans)..where((p) => p.id.equals(plan.id))).write(
      const PlansCompanion(active: Value(true)),
    );
  });

  Future<void> deletePlan(int id) =>
      (_db.delete(_db.plans)..where((p) => p.id.equals(id))).go();

  Future<void> _deactivateAll(int profileId) =>
      (_db.update(_db.plans)..where((p) => p.profileId.equals(profileId)))
          .write(const PlansCompanion(active: Value(false)));

  // --- Days ----------------------------------------------------------------

  /// A plan's days with their exercises, in schedule order.
  Stream<List<PlanDayDetail>> watchDays(int planId) => _db.watchLoad([
    _db.plans,
    _db.planDays,
    _db.planItems,
    _db.exercises,
  ], () => _loadDays(planId));

  Future<int> addDay({
    required int planId,
    required String name,
    int? weekday,
  }) async {
    final count = (await _days(planId)).length;
    return _db
        .into(_db.planDays)
        .insert(
          PlanDaysCompanion.insert(
            planId: planId,
            name: name.trim(),
            weekday: Value(weekday),
            position: count,
          ),
        );
  }

  Future<void> updateDay(int id, {required String name, int? weekday}) =>
      (_db.update(_db.planDays)..where((d) => d.id.equals(id))).write(
        PlanDaysCompanion(name: Value(name.trim()), weekday: Value(weekday)),
      );

  Future<void> deleteDay(int id) =>
      (_db.delete(_db.planDays)..where((d) => d.id.equals(id))).go();

  /// Saves the order of a rotation plan's days.
  Future<void> reorderDays(List<int> dayIds) => _db.batch((b) {
    for (final (i, id) in dayIds.indexed) {
      b.update(
        _db.planDays,
        PlanDaysCompanion(position: Value(i)),
        where: (d) => d.id.equals(id),
      );
    }
  });

  // --- Items ---------------------------------------------------------------

  /// Adds [exercises] to the end of a day with targets suggested by [cycle].
  Future<void> addItems(
    int dayId,
    List<Exercise> exercises, {
    CycleType? cycle,
  }) => _db.transaction(() async {
    final existing = await (_db.select(
      _db.planItems,
    )..where((i) => i.planDayId.equals(dayId))).get();
    await _db.batch((b) {
      for (final (i, e) in exercises.indexed) {
        final t = defaultTargets(e.tracking, cycle);
        b.insert(
          _db.planItems,
          PlanItemsCompanion.insert(
            planDayId: dayId,
            exerciseId: e.id,
            position: existing.length + i,
            targetSets: t.sets,
            targetReps: Value(t.reps),
            targetWeightKg: Value(t.weightKg),
            targetDurationSec: Value(t.durationSec),
            targetDistanceKm: Value(t.distanceKm),
            restSec: Value(t.restSec),
          ),
        );
      }
    });
  });

  Future<void> updateItem(int id, Targets t) =>
      (_db.update(_db.planItems)..where((i) => i.id.equals(id))).write(
        PlanItemsCompanion(
          targetSets: Value(t.sets),
          targetReps: Value(t.reps),
          targetWeightKg: Value(t.weightKg),
          targetDurationSec: Value(t.durationSec),
          targetDistanceKm: Value(t.distanceKm),
          restSec: Value(t.restSec),
        ),
      );

  Future<void> deleteItem(int id) =>
      (_db.delete(_db.planItems)..where((i) => i.id.equals(id))).go();

  Future<void> reorderItems(List<int> itemIds) => _db.batch((b) {
    for (final (i, id) in itemIds.indexed) {
      b.update(
        _db.planItems,
        PlanItemsCompanion(position: Value(i)),
        where: (t) => t.id.equals(id),
      );
    }
  });

  // --- Today ---------------------------------------------------------------

  /// What the profile's active plan says to train on the day [now] returns,
  /// or null when no plan is active.
  Stream<TodayPlan?> watchToday(int profileId, {DateTime Function()? now}) =>
      _db.watchLoad([
        _db.plans,
        _db.planDays,
        _db.planItems,
        _db.exercises,
        _db.sessions,
      ], () => todayFor(profileId, (now ?? DateTime.now)()));

  Future<TodayPlan?> todayFor(int profileId, DateTime now) async {
    final plan =
        await (_db.select(_db.plans)
              ..where((p) => p.profileId.equals(profileId) & p.active)
              ..limit(1))
            .getSingleOrNull();
    if (plan == null) return null;
    final days = await _loadDays(plan.id);
    if (days.isEmpty) return TodayPlan(plan: plan, days: days);

    final dayIds = [for (final d in days) d.day.id];
    final last =
        await (_db.select(_db.sessions)
              ..where(
                (s) =>
                    s.profileId.equals(profileId) &
                    s.endedAt.isNotNull() &
                    s.planDayId.isIn(dayIds),
              )
              ..orderBy([(s) => OrderingTerm.desc(s.startedAt)])
              ..limit(1))
            .getSingleOrNull();
    final lastWasToday =
        last != null && dateOnly(last.startedAt) == dateOnly(now);
    PlanDayDetail byId(int? id) => days.firstWhere((d) => d.day.id == id);

    switch (plan.schedule) {
      case PlanSchedule.weekly:
        final wd = now.weekday;
        final today = days.where((d) => d.day.weekday == wd).firstOrNull;
        if (today != null) {
          return TodayPlan(
            plan: plan,
            days: days,
            today: today,
            doneToday: lastWasToday && last.planDayId == today.day.id,
          );
        }
        int ahead(PlanDayDetail d) => ((d.day.weekday ?? wd) - wd + 7) % 7;
        final next = [...days]..sort((a, b) => ahead(a) - ahead(b));
        return TodayPlan(plan: plan, days: days, next: next.first);
      case PlanSchedule.rotation:
        // Stay on a day trained today, so finishing it shows it as done
        // rather than jumping straight to the next one.
        if (lastWasToday) {
          return TodayPlan(
            plan: plan,
            days: days,
            today: byId(last.planDayId),
            doneToday: true,
          );
        }
        final i = last == null
            ? 0
            : (days.indexWhere((d) => d.day.id == last.planDayId) + 1) %
                  days.length;
        return TodayPlan(plan: plan, days: days, today: days[i]);
    }
  }

  // --- Helpers -------------------------------------------------------------

  Future<List<PlanDay>> _days(int planId) =>
      (_db.select(_db.planDays)
            ..where((d) => d.planId.equals(planId))
            ..orderBy([(d) => OrderingTerm.asc(d.position)]))
          .get();

  /// Weekly plans follow the week; rotation plans their own order.
  List<PlanDay> _sortDays(Plan plan, List<PlanDay> days) {
    if (plan.schedule == PlanSchedule.weekly) {
      days.sort((a, b) => (a.weekday ?? 8) - (b.weekday ?? 8));
    }
    return days;
  }

  Future<List<PlanDayDetail>> _loadDays(int planId) async {
    final plan = await (_db.select(
      _db.plans,
    )..where((p) => p.id.equals(planId))).getSingleOrNull();
    if (plan == null) return const [];
    final days = _sortDays(plan, await _days(planId));
    final rows =
        await (_db.select(_db.planItems).join([
                innerJoin(
                  _db.exercises,
                  _db.exercises.id.equalsExp(_db.planItems.exerciseId),
                ),
                innerJoin(
                  _db.planDays,
                  _db.planDays.id.equalsExp(_db.planItems.planDayId),
                  useColumns: false,
                ),
              ])
              ..where(_db.planDays.planId.equals(planId))
              ..orderBy([OrderingTerm.asc(_db.planItems.position)]))
            .get();
    final byDay = <int, List<PlanItemDetail>>{};
    for (final r in rows) {
      final item = r.readTable(_db.planItems);
      (byDay[item.planDayId] ??= []).add(
        PlanItemDetail(item, r.readTable(_db.exercises)),
      );
    }
    return [for (final d in days) PlanDayDetail(d, byDay[d.id] ?? const [])];
  }
}
