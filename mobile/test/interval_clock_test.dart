import 'package:fitmeasure/domain/interval_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 8, 18);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test(
    'interval rounds: ready, then work and rest, no rest after the last',
    () {
      expect(intervalPhases(sets: [2, 3, 4], workSec: 40, restSec: 20), const [
        TimerPhase(PhaseKind.ready, 5, setNumber: 2),
        TimerPhase(PhaseKind.work, 40, setNumber: 2),
        TimerPhase(PhaseKind.rest, 20, setNumber: 3),
        TimerPhase(PhaseKind.work, 40, setNumber: 3),
        TimerPhase(PhaseKind.rest, 20, setNumber: 4),
        TimerPhase(PhaseKind.work, 40, setNumber: 4),
      ]);
      expect(intervalPhases(sets: [1], workSec: 30, readySec: 0), const [
        TimerPhase(PhaseKind.work, 30, setNumber: 1),
      ]);
    },
  );

  test('runs through the phases on time, even when checked late', () {
    final c = IntervalClock(
      intervalPhases(sets: [1, 2], workSec: 40, restSec: 20),
    )..start(t0);
    expect(c.left(at(2)), const Duration(seconds: 3));
    expect(c.advance(at(4)), isEmpty);

    // The phone was asleep through getting ready and most of set 1.
    final ended = c.advance(at(40));
    expect(ended.map((p) => p.kind), [PhaseKind.ready]);
    expect(c.phase!.kind, PhaseKind.work);
    expect(c.left(at(40)), const Duration(seconds: 5), reason: 'ends at 45');

    final more = c.advance(at(70));
    expect(more.map((p) => p.kind), [PhaseKind.work, PhaseKind.rest]);
    expect(c.left(at(70)), const Duration(seconds: 35));
    c.advance(at(105));
    expect(c.done, isTrue);
    expect(c.running, isFalse);
  });

  test('pausing keeps the time left', () {
    final c = IntervalClock([const TimerPhase(PhaseKind.work, 30)])..start(t0);
    c.pause(at(10));
    expect(c.running, isFalse);
    expect(c.advance(at(100)), isEmpty);
    expect(c.left(at(100)), const Duration(seconds: 20));
    c.start(at(100));
    expect(c.advance(at(119)), isEmpty);
    expect(c.advance(at(120)), hasLength(1));
    expect(c.done, isTrue);
  });

  test('skipping starts the next phase in full', () {
    final c = IntervalClock(
      intervalPhases(sets: [1, 2], workSec: 40, restSec: 20, readySec: 0),
    )..start(t0);
    expect(c.skip(at(15))!.kind, PhaseKind.work);
    expect(c.phase!.kind, PhaseKind.rest);
    expect(c.left(at(15)), const Duration(seconds: 20));
    c.pause(at(20));
    c.skip(at(30));
    expect(c.phase!.kind, PhaseKind.work);
    expect(c.running, isFalse, reason: 'still paused');
    expect(c.left(at(30)), const Duration(seconds: 40));
    c.skip(at(31));
    expect(c.done, isTrue);
    expect(c.skip(at(32)), isNull);
  });
}
