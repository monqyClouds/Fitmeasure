/// The phases of timed sets, and a clock that runs through them.
library;

enum PhaseKind { ready, work, rest }

/// One stretch of the timer: getting ready, working a set, or resting.
class TimerPhase {
  const TimerPhase(this.kind, this.seconds, {this.setNumber});
  final PhaseKind kind;
  final int seconds;

  /// The set being worked, or (for rest and getting ready) the next one.
  final int? setNumber;

  @override
  bool operator ==(Object other) =>
      other is TimerPhase &&
      other.kind == kind &&
      other.seconds == seconds &&
      other.setNumber == setNumber;

  @override
  int get hashCode => Object.hash(kind, seconds, setNumber);

  @override
  String toString() => '${kind.name}($seconds s, set $setNumber)';
}

/// Timed sets run back to back: a few seconds to get ready, then each set
/// with rest between (none after the last).
List<TimerPhase> intervalPhases({
  required List<int> sets,
  required int workSec,
  int restSec = 0,
  int readySec = 5,
}) => [
  if (readySec > 0 && sets.isNotEmpty)
    TimerPhase(PhaseKind.ready, readySec, setNumber: sets.first),
  for (final (i, n) in sets.indexed) ...[
    TimerPhase(PhaseKind.work, workSec, setNumber: n),
    if (restSec > 0 && i < sets.length - 1)
      TimerPhase(PhaseKind.rest, restSec, setNumber: sets[i + 1]),
  ],
];

/// Runs through [phases]. Kept as end times rather than ticks, so it stays
/// right while the screen is off. The time is passed in, for tests.
class IntervalClock {
  IntervalClock(this.phases);

  final List<TimerPhase> phases;

  int _index = 0;
  DateTime? _endsAt; // while running
  Duration? _left; // while paused, or before starting

  int get index => _index;
  bool get done => _index >= phases.length;
  bool get running => _endsAt != null && !done;
  bool get started => _endsAt != null || _left != null;
  TimerPhase? get phase => done ? null : phases[_index];

  /// The time left in the current phase.
  Duration left(DateTime now) {
    if (done) return Duration.zero;
    final ends = _endsAt;
    if (ends != null) {
      final d = ends.difference(now);
      return d.isNegative ? Duration.zero : d;
    }
    return _left ?? Duration(seconds: phases[_index].seconds);
  }

  void start(DateTime now) {
    if (done || running) return;
    _endsAt = now.add(left(now));
    _left = null;
  }

  void pause(DateTime now) {
    if (!running) return;
    _left = left(now);
    _endsAt = null;
  }

  /// Moves on through every phase that has ended by [now], carrying the
  /// overrun into the next so a late check doesn't shorten anything, and
  /// returns the phases that ended.
  List<TimerPhase> advance(DateTime now) {
    final ended = <TimerPhase>[];
    var ends = _endsAt;
    while (ends != null && !done && !now.isBefore(ends)) {
      ended.add(phases[_index]);
      _index++;
      ends = done ? null : ends.add(Duration(seconds: phases[_index].seconds));
    }
    _endsAt = ends;
    return ended;
  }

  /// Ends the current phase now, as if its time were up, and returns it.
  TimerPhase? skip(DateTime now) {
    if (done) return null;
    final skipped = phases[_index];
    _index++;
    if (done) {
      _endsAt = _left = null;
    } else if (_endsAt != null) {
      _endsAt = now.add(Duration(seconds: phases[_index].seconds));
    } else {
      _left = null;
    }
    return skipped;
  }
}
