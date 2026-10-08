import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/backup/backup_service.dart';
import '../data/db/database.dart';
import '../data/link_preview.dart';
import '../data/sharing.dart';
import '../data/repos/cycle_repo.dart';
import '../data/repos/exercise_repo.dart';
import '../data/repos/measurement_repo.dart';
import '../data/repos/plan_repo.dart';
import '../data/repos/profile_repo.dart';
import '../data/repos/session_repo.dart';
import '../data/repos/settings_repo.dart';
import '../data/repos/strength_repo.dart';
import '../domain/strength.dart';

/// The app's documents folder, which media paths are relative to.
/// Overridden in main().
final documentsPathProvider = Provider<String>(
  (ref) => throw UnimplementedError('documentsPathProvider must be overridden'),
);

/// Overridden in main() (and in tests) with a concrete database.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final profileRepoProvider = Provider(
  (ref) => ProfileRepo(ref.watch(databaseProvider)),
);
final cycleRepoProvider = Provider(
  (ref) => CycleRepo(ref.watch(databaseProvider)),
);
final exerciseRepoProvider = Provider(
  (ref) => ExerciseRepo(ref.watch(databaseProvider)),
);
final linkPreviewerProvider = Provider((ref) => LinkPreviewer());
final planRepoProvider = Provider(
  (ref) => PlanRepo(ref.watch(databaseProvider)),
);
final sharingProvider = Provider(
  (ref) => Sharing(ref.watch(databaseProvider), ref.watch(planRepoProvider)),
);
final sessionRepoProvider = Provider(
  (ref) => SessionRepo(ref.watch(databaseProvider)),
);
final measurementRepoProvider = Provider(
  (ref) => MeasurementRepo(ref.watch(databaseProvider)),
);
final strengthRepoProvider = Provider(
  (ref) => StrengthRepo(ref.watch(databaseProvider)),
);
final settingsRepoProvider = Provider(
  (ref) => SettingsRepo(ref.watch(databaseProvider)),
);
final backupServiceProvider = Provider(
  (ref) => BackupService(ref.watch(databaseProvider)),
);

// --- Profiles --------------------------------------------------------------

final profilesProvider = StreamProvider(
  (ref) => ref.watch(profileRepoProvider).watchAll(),
);

/// The profile currently training, or null while on the picker screen.
class CurrentProfileId extends Notifier<int?> {
  @override
  int? build() => null;

  Future<void> select(int? id) async {
    state = id;
    await ref.read(profileRepoProvider).setLastUsed(id);
  }
}

final currentProfileIdProvider = NotifierProvider<CurrentProfileId, int?>(
  CurrentProfileId.new,
);

final currentProfileProvider = StreamProvider<Profile?>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(null);
  return ref.watch(profileRepoProvider).watch(id);
});

/// Requires a selected profile; only used below the profile picker.
int requireProfileId(Ref ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) throw StateError('No profile selected');
  return id;
}

// --- Cycles ----------------------------------------------------------------

final cyclesProvider = StreamProvider<List<Cycle>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(cycleRepoProvider).watchForProfile(id);
});

final activeCycleProvider = Provider<Cycle?>((ref) {
  final cycles = ref.watch(cyclesProvider).value ?? const [];
  for (final c in cycles) {
    if (c.isActive) return c;
  }
  return null;
});

// --- Exercises -------------------------------------------------------------

final libraryProvider = StreamProvider<List<ExerciseWithMedia>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(exerciseRepoProvider).watchLibrary(id);
});

final exerciseProvider = StreamProvider.autoDispose.family<Exercise?, int>(
  (ref, id) => ref.watch(exerciseRepoProvider).watch(id),
);

final exerciseMediaProvider = StreamProvider.autoDispose
    .family<List<MediaItem>, int>((ref, exerciseId) {
      final profileId = requireProfileId(ref);
      return ref.watch(exerciseRepoProvider).watchMedia(exerciseId, profileId);
    });

// --- Plans -----------------------------------------------------------------

final plansProvider = StreamProvider<List<PlanOverview>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(planRepoProvider).watchPlans(id);
});

final planProvider = StreamProvider.autoDispose.family<Plan?, int>(
  (ref, id) => ref.watch(planRepoProvider).watchPlan(id),
);

final planDaysProvider = StreamProvider.autoDispose
    .family<List<PlanDayDetail>, int>(
      (ref, planId) => ref.watch(planRepoProvider).watchDays(planId),
    );

/// What the active plan says to train today.
final todayPlanProvider = StreamProvider<TodayPlan?>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(null);
  return ref.watch(planRepoProvider).watchToday(id);
});

// --- Workouts --------------------------------------------------------------

/// The unfinished workout of the current profile, if any.
final activeSessionProvider = StreamProvider<Session?>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(null);
  return ref.watch(sessionRepoProvider).watchActive(id);
});

final workoutProvider = StreamProvider.autoDispose.family<Workout?, int>(
  (ref, sessionId) => ref.watch(sessionRepoProvider).watchWorkout(sessionId),
);

final recentSessionsProvider = StreamProvider<List<SessionSummary>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(sessionRepoProvider).watchRecent(id);
});

/// Sets of an exercise from the last finished workout other than the given
/// session, keyed by (exercise id, session id).
final lastSetsProvider = FutureProvider.autoDispose
    .family<List<SetLog>, (int, int)>((ref, key) {
      final (exerciseId, sessionId) = key;
      return ref
          .watch(sessionRepoProvider)
          .lastSets(
            profileId: requireProfileId(ref),
            exerciseId: exerciseId,
            excludeSessionId: sessionId,
          );
    });

/// Exercises where a workout set a new heaviest weight, with the weight.
final weightRecordsProvider = FutureProvider.autoDispose
    .family<Map<int, double>, int>(
      (ref, sessionId) =>
          ref.watch(sessionRepoProvider).weightRecords(sessionId),
    );

/// Every finished workout of the current profile, for Progress.
final allSessionsProvider = StreamProvider<List<SessionSummary>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(sessionRepoProvider).watchRecent(id, limit: 100000);
});

// --- Measurements ----------------------------------------------------------

/// Every measurement type of the current profile with its entries.
final measurementsProvider = StreamProvider<List<MeasurementSeries>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(measurementRepoProvider).watchAll(id);
});

final measurementSeriesProvider = StreamProvider.autoDispose
    .family<MeasurementSeries?, int>(
      (ref, typeId) => ref
          .watch(measurementRepoProvider)
          .watchSeries(requireProfileId(ref), typeId),
    );

// --- Strength --------------------------------------------------------------

/// Every exercise the current profile has logged, most recent first.
final strengthTrendsProvider = StreamProvider<List<ExerciseTrend>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(strengthRepoProvider).watchTrends(id);
});

final exerciseTrendProvider = StreamProvider.autoDispose
    .family<ExerciseTrend?, int>(
      (ref, exerciseId) => ref
          .watch(strengthRepoProvider)
          .watchTrend(requireProfileId(ref), exerciseId),
    );

// --- Settings --------------------------------------------------------------

/// Keep the screen on while a workout is open. On unless turned off.
final keepAwakeProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepoProvider)
      .watchBool(SettingsRepo.keepAwake, fallback: true),
);
