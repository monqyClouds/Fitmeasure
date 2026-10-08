import 'package:drift/drift.dart';

import '../../domain/enums.dart';

// Units are metric throughout: weight in kg, lengths in cm, distance in km,
// durations in seconds.

class Profiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 40)();
  IntColumn get color => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Cycles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get type => textEnum<CycleType>()();
  TextColumn get name => text()();
  DateTimeColumn get startDate => dateTime()();

  /// Null for open-ended cycles (e.g. a routine).
  DateTimeColumn get endDate => dateTime().nullable()();
  RealColumn get goalWeightKg => real().nullable()();
  TextColumn get notes => text().nullable()();
}

class Exercises extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Null for the built-in library shared by all profiles.
  IntColumn get profileId => integer().nullable().references(
    Profiles,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get name => text().withLength(min: 1, max: 60)();
  TextColumn get muscle => textEnum<MuscleGroup>()();
  TextColumn get equipment => textEnum<Equipment>()();
  TextColumn get tracking => textEnum<TrackingType>()();
  TextColumn get notes => text().nullable()();
}

@DataClassName('MediaItem')
class ExerciseMedia extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind => textEnum<MediaKind>()();

  /// Absolute path inside the app's storage for images/videos, or a URL.
  TextColumn get uri => text()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Plans extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get cycleId => integer().nullable().references(
    Cycles,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get name => text()();
  TextColumn get schedule => textEnum<PlanSchedule>()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class PlanDays extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get planId =>
      integer().references(Plans, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();

  /// 1 = Monday … 7 = Sunday for weekly plans; null for rotation plans.
  IntColumn get weekday => integer().nullable()();
  IntColumn get position => integer()();
}

class PlanItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get planDayId =>
      integer().references(PlanDays, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  IntColumn get targetSets => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetDurationSec => integer().nullable()();
  RealColumn get targetDistanceKm => real().nullable()();
  IntColumn get restSec => integer().nullable()();
}

class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get planDayId => integer().nullable().references(
    PlanDays,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get cycleId => integer().nullable().references(
    Cycles,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get name => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  TextColumn get notes => text().nullable()();
}

/// An exercise in a workout, with the targets copied from the plan when the
/// workout starts (or cycle defaults when added during it), so the workout
/// can be resumed and plan edits don't change it.
class SessionExercises extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  IntColumn get targetSets => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetDurationSec => integer().nullable()();
  RealColumn get targetDistanceKm => real().nullable()();
  IntColumn get restSec => integer().nullable()();
}

/// One performed set. Targets are copied from the plan at logging time so
/// history stays accurate when the plan is edited later.
class SetLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(Sessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get exerciseId =>
      integer().references(Exercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get setNumber => integer()();
  IntColumn get targetReps => integer().nullable()();
  RealColumn get targetWeightKg => real().nullable()();
  IntColumn get targetDurationSec => integer().nullable()();
  RealColumn get targetDistanceKm => real().nullable()();
  IntColumn get reps => integer().nullable()();
  RealColumn get weightKg => real().nullable()();
  IntColumn get durationSec => integer().nullable()();
  RealColumn get distanceKm => real().nullable()();

  /// Rest taken before this set, measured automatically.
  IntColumn get restSec => integer().nullable()();
  DateTimeColumn get completedAt => dateTime()();
}

class MeasurementTypes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get unit => text()();
  IntColumn get position => integer()();
}

class Measurements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get typeId => integer().references(
    MeasurementTypes,
    #id,
    onDelete: KeyAction.cascade,
  )();
  RealColumn get value => real()();
  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get note => text().nullable()();
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
