import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/repos/cycle_repo.dart';
import '../data/repos/exercise_repo.dart';
import '../data/repos/profile_repo.dart';

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
