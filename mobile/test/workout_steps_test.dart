import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/domain/targets.dart';
import 'package:fitmeasure/features/live/live_protocol.dart';
import 'package:fitmeasure/features/live/workout_steps.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  setUp(
    () => db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    ),
  );
  tearDown(() => db.close());

  Future<Exercise> exercise(String name) =>
      (db.select(db.exercises)..where((e) => e.name.equals(name))).getSingle();

  Targets targets({
    int sets = 2,
    int? reps,
    double? kg,
    int? secs,
    int? rest,
  }) => (
    sets: sets,
    reps: reps,
    weightKg: kg,
    durationSec: secs,
    distanceKm: null,
    restSec: rest,
  );

  test('timed sets count down; sets of reps wait; rest between all but the '
      'last', () async {
    final plank = await exercise('Plank');
    final squat = await exercise('Back Squat');
    final steps = workoutSteps([
      (plank, targets(secs: 40, rest: 20)),
      (squat, targets(reps: 8, kg: 60, rest: 90)),
    ]);
    expect(steps, const [
      WorkoutStep(kind: 'work', title: 'Plank', seconds: 40, set: 1, sets: 2),
      WorkoutStep(
        kind: 'rest',
        title: 'Rest',
        detail: 'Next: Plank, set 2',
        seconds: 20,
      ),
      WorkoutStep(kind: 'work', title: 'Plank', seconds: 40, set: 2, sets: 2),
      WorkoutStep(
        kind: 'rest',
        title: 'Rest',
        detail: 'Next: Back Squat, set 1',
        seconds: 20,
      ),
      WorkoutStep(
        kind: 'work',
        title: 'Back Squat',
        detail: '60 kg × 8',
        set: 1,
        sets: 2,
      ),
      WorkoutStep(
        kind: 'rest',
        title: 'Rest',
        detail: 'Next: Back Squat, set 2',
        seconds: 90,
      ),
      WorkoutStep(
        kind: 'work',
        title: 'Back Squat',
        detail: '60 kg × 8',
        set: 2,
        sets: 2,
      ),
    ]);
    expect(timedSeconds(steps), 40 * 2 + 20 * 2 + 90);
  });

  test('a workout goes to the server as its title and steps, and comes back '
      'with where it is', () {
    final load = SignalMessage(
      type: SignalType.workoutLoad,
      workout: const LiveWorkout(
        title: 'Core',
        steps: [WorkoutStep(kind: 'work', title: 'Plank', seconds: 30)],
      ),
    ).encode();
    expect(
      load,
      '{"type":"workout_load","workout":{"title":"Core","steps":'
      '[{"kind":"work","title":"Plank","seconds":30}]}}',
    );
    expect(
      SignalMessage(
        type: SignalType.workoutControl,
        action: WorkoutAction.breakNow,
        seconds: 60,
      ).encode(),
      '{"type":"workout_control","action":"break","seconds":60}',
    );

    final m = SignalMessage.decode(
      '{"type":"workout","workout":{"title":"Core","index":1,'
      '"running":true,"remainingMs":12345,"steps":['
      '{"kind":"break","title":"Water break","seconds":60},'
      '{"kind":"work","title":"Plank","seconds":30,"set":1,"sets":3}]}}',
    );
    final w = m.workout!;
    expect(w.index, 1);
    expect(w.running, isTrue);
    expect(w.remainingMs, 12345);
    expect(w.step!.title, 'Plank');
    expect(w.step!.sets, 3);
    expect(w.next, isNull);
    expect(w.finished, isFalse);
    // Stopped: a workout message with no workout.
    expect(SignalMessage.decode('{"type":"workout"}').workout, isNull);
  });
}
