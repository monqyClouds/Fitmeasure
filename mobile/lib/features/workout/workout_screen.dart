import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/session_repo.dart';
import '../../domain/enums.dart';
import '../../domain/units.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';
import '../library/exercise_detail_screen.dart';
import '../library/exercise_picker_screen.dart';
import '../library/muscle_icon.dart';
import '../library/video_links.dart';
import '../plans/targets_sheet.dart';
import 'rest_timer.dart';
import 'session_detail_screen.dart';

/// A workout in progress: tick off each set against its target.
class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key, required this.sessionId});
  final int sessionId;

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<WorkoutScreen> {
  var _closing = false;

  @override
  void initState() {
    super.initState();
    _applyWakelock(ref.read(keepAwakeProvider).value ?? true);
  }

  @override
  void dispose() {
    // The screen may sleep again once the workout is closed.
    WakelockPlus.disable().ignore();
    super.dispose();
  }

  void _applyWakelock(bool on) =>
      (on ? WakelockPlus.enable() : WakelockPlus.disable()).ignore();

  SessionRepo get _repo => ref.read(sessionRepoProvider);

  Future<void> _addExercises(Workout w) async {
    final picked = await pickExercises(
      context,
      exclude: {for (final e in w.exercises) e.exercise.id},
    );
    if (picked == null || picked.isEmpty) return;
    await _repo.addExercises(
      widget.sessionId,
      picked,
      cycle: ref.read(activeCycleProvider)?.type,
    );
  }

  Future<void> _discard() async {
    final ok = await confirmDialog(
      context,
      title: 'Discard workout?',
      message: 'Nothing from this workout will be saved.',
      confirmLabel: 'Discard',
    );
    if (!ok) return;
    _closing = true;
    ref.read(restTimerProvider.notifier).stop();
    await _repo.delete(widget.sessionId);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _finish(Workout w) async {
    if (w.loggedSets == 0) {
      final ok = await confirmDialog(
        context,
        title: 'Nothing logged yet',
        message:
            'Tick off at least one set to save this workout, or '
            'discard it.',
        confirmLabel: 'Discard',
      );
      if (!ok) return;
      _closing = true;
      await _repo.delete(widget.sessionId);
      if (mounted) Navigator.pop(context);
      return;
    }
    if (w.remainingSets > 0) {
      final ok = await confirmDialog(
        context,
        title: 'Finish workout?',
        message: w.remainingSets == 1
            ? '1 planned set isn\'t ticked off. It won\'t be saved.'
            : '${w.remainingSets} planned sets aren\'t ticked off. They '
                  'won\'t be saved.',
        confirmLabel: 'Finish',
        destructive: false,
      );
      if (!ok) return;
    }
    _closing = true;
    ref.read(restTimerProvider.notifier).stop();
    await _repo.finish(widget.sessionId);
    HapticFeedback.heavyImpact();
    if (!mounted) return;
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          sessionId: widget.sessionId,
          justFinished: true,
        ),
      ),
    );
  }

  Future<void> _begin() async {
    HapticFeedback.mediumImpact();
    await _repo.begin(widget.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    ref.listen(keepAwakeProvider, (_, next) {
      if (next.value case final on?) _applyWakelock(on);
    });
    final async = ref.watch(workoutProvider(widget.sessionId));
    final w = async.value;
    if (w == null) {
      if (async.hasValue && !_closing) {
        // Deleted elsewhere, e.g. from another screen.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
      return const Scaffold(backgroundColor: AppColors.background);
    }

    final total = w.loggedSets + w.remainingSets;
    final doneExercises = w.exercises
        .where((e) => e.sets.length >= e.rowCount && e.rowCount > 0)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Text(w.session.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (a) {
              if (a == 'discard') _discard();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'discard', child: Text('Discard workout')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: const RestTimerBar(),
      body: GlowBackdrop(
        color: accent,
        height: 260,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              // Let the card's glow spill out.
              clipBehavior: Clip.none,
              child: w.session.started
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _StartCard(
                        ready: w.exercises.isNotEmpty,
                        onStart: _begin,
                      ),
                    ),
            ),
            FadeSlideIn(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                child: Row(
                  children: [
                    ProgressRing(
                      value: total == 0 ? 0 : w.loggedSets / total,
                      color: accent,
                      size: 124,
                      stroke: 11,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedCount(
                            value: w.loggedSets,
                            style: t.headlineMedium,
                          ),
                          Text(
                            'of $total sets',
                            style: t.bodySmall!.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HeaderStat(
                            icon: Icons.timer_outlined,
                            color: CycleType.endurance.color,
                            label: 'Elapsed',
                            value: w.session.started
                                ? ElapsedText(
                                    since: w.session.startedAt,
                                    style: t.titleMedium,
                                  )
                                : Text('0:00', style: t.titleMedium),
                          ),
                          const SizedBox(height: 12),
                          _HeaderStat(
                            icon: Icons.scale_rounded,
                            color: CycleType.bulk.color,
                            label: 'Volume',
                            value: Text(
                              formatKg(w.volumeKg),
                              style: t.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _HeaderStat(
                            icon: Icons.check_circle_outline_rounded,
                            color: accent,
                            label: 'Exercises done',
                            value: Text(
                              '$doneExercises / ${w.exercises.length}',
                              style: t.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (w.exercises.isEmpty)
              EmptyState(
                icon: Icons.playlist_add_rounded,
                title: 'Add your first exercise',
                message:
                    'Pick exercises from the library, then tick off each set '
                    'as you go.',
                action: FilledButton.icon(
                  onPressed: () => _addExercises(w),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add exercises'),
                ),
              )
            else ...[
              for (final (i, e) in w.exercises.indexed)
                FadeSlideIn.staggered(
                  key: ValueKey(e.entry.id),
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _ExerciseCard(we: e, sessionId: widget.sessionId),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => _addExercises(w),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add exercise'),
              ),
            ],
            if (w.session.started) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _finish(w),
                icon: const Icon(Icons.flag_rounded),
                label: const Text('Finish workout'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown above a workout that's being set up: the clock waits for Start.
class _StartCard extends StatelessWidget {
  const _StartCard({required this.ready, required this.onStart});

  /// Whether exercises have been added yet.
  final bool ready;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final on = onColor(accent);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onStart,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: [accent, Color.lerp(accent, Colors.black, 0.25)!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'READY WHEN YOU ARE',
                      style: t.labelSmall!.copyWith(
                        color: on.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Start workout',
                      style: t.titleLarge!.copyWith(color: on),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ready
                          ? 'The clock starts when you tap'
                          : 'Add your exercises, then start the clock',
                      style: t.bodySmall!.copyWith(
                        color: on.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _PulsingPlay(color: accent, background: on),
            ],
          ),
        ),
      ),
    );
  }
}

/// A play button with a soft ring breathing around it.
class _PulsingPlay extends StatefulWidget {
  const _PulsingPlay({required this.color, required this.background});
  final Color color;
  final Color background;

  @override
  State<_PulsingPlay> createState() => _PulsingPlayState();
}

class _PulsingPlayState extends State<_PulsingPlay>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 72,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final v = Curves.easeOut.transform(_pulse.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 56 + 16 * v,
                height: 56 + 16 * v,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.background.withValues(alpha: 0.35 * (1 - v)),
                ),
              ),
              child!,
            ],
          );
        },
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: widget.background,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.play_arrow_rounded, color: widget.color, size: 34),
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              value,
              Text(
                label,
                style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({required this.we, required this.sessionId});
  final WorkoutExercise we;
  final int sessionId;

  Future<void> _menu(BuildContext context, WidgetRef ref, String a) async {
    final repo = ref.read(sessionRepoProvider);
    switch (a) {
      case 'targets':
        final t = await showTargetsSheet(
          context,
          exercise: we.exercise,
          initial: we.targets,
        );
        if (t != null) await repo.updateTargets(we.entry.id, t);
      case 'remove_set':
        await repo.setTargetSets(we.entry.id, we.rowCount - 1);
      case 'remove':
        if (we.sets.isNotEmpty) {
          final ok = await confirmDialog(
            context,
            title: 'Remove ${we.exercise.name}?',
            message: 'The sets you logged for it are removed too.',
            confirmLabel: 'Remove',
          );
          if (!ok) return;
        }
        await repo.removeExercise(we.entry);
      case 'details':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ExerciseDetailScreen(exerciseId: we.exercise.id),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final e = we.exercise;
    final color = e.muscle.color;
    final last =
        ref.watch(lastSetsProvider((e.id, sessionId))).value ?? const [];
    final rows = we.rowCount;
    final done = we.sets.length;
    final complete = rows > 0 && done >= rows;
    final lastRowPending = rows > 1 && we.logged(rows) == null;
    final videos = [
      for (final m
          in ref.watch(exerciseMediaProvider(e.id)).value ??
              const <MediaItem>[])
        if (m.kind == MediaKind.link) m,
    ];
    final lastText = [
      for (final s in last.take(4))
        describeSet(
          e.tracking,
          reps: s.reps,
          weightKg: s.weightKg,
          durationSec: s.durationSec,
          distanceKm: s.distanceKm,
        ),
    ].where((s) => s.isNotEmpty).join('  ·  ');

    return AnimatedContainer(
      duration: Motion.medium,
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(
          color: complete ? color.withValues(alpha: 0.5) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MuscleIcon(muscle: e.muscle, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      style: t.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          lastText.isEmpty
                              ? Icons.auto_awesome_rounded
                              : Icons.history_rounded,
                          size: 13,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            lastText.isEmpty ? 'First time' : lastText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall!.copyWith(
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (videos.isNotEmpty)
                IconButton(
                  tooltip: 'Watch form',
                  onPressed: () => videos.length == 1
                      ? openVideoLink(context, videos.single)
                      : showFormVideos(context, e.name, videos, color),
                  icon: Icon(Icons.smart_display_rounded, color: color),
                ),
              ProgressRing(
                value: rows == 0 ? 0 : done / rows,
                color: color,
                size: 40,
                stroke: 4,
                child: complete
                    ? Icon(Icons.check_rounded, size: 18, color: color)
                    : Text('$done/$rows', style: t.labelSmall),
              ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: AppColors.textTertiary,
                ),
                onSelected: (a) => _menu(context, ref, a),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'targets',
                    child: Text('Edit targets'),
                  ),
                  if (lastRowPending)
                    const PopupMenuItem(
                      value: 'remove_set',
                      child: Text('Remove last set'),
                    ),
                  PopupMenuItem(
                    value: 'details',
                    child: Text(
                      videos.isEmpty ? 'Add a form video' : 'Exercise details',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove exercise'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ColumnLabels(tracking: e.tracking),
          for (var n = 1; n <= rows; n++)
            _SetRow(
              key: ValueKey('${we.entry.id}-$n'),
              we: we,
              number: n,
              lastTime: last.where((s) => s.setNumber == n).firstOrNull,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => ref
                  .read(sessionRepoProvider)
                  .setTargetSets(we.entry.id, rows + 1),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add set'),
              style: TextButton.styleFrom(foregroundColor: color),
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _fieldLabels(TrackingType tracking) => switch (tracking) {
  TrackingType.reps => ['KG', 'REPS'],
  TrackingType.time => ['TIME'],
  TrackingType.distance => ['KM', 'TIME'],
};

class _ColumnLabels extends StatelessWidget {
  const _ColumnLabels({required this.tracking});
  final TrackingType tracking;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall!
        .copyWith(color: AppColors.textTertiary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('SET', style: style, textAlign: TextAlign.center),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 64, child: Text('TARGET', style: style)),
          for (final l in _fieldLabels(tracking)) ...[
            Expanded(
              child: Text(l, style: style, textAlign: TextAlign.center),
            ),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 44),
        ],
      ),
    );
  }
}

/// One set: its target, fields for what was done, and a tick to log it.
class _SetRow extends ConsumerStatefulWidget {
  const _SetRow({
    super.key,
    required this.we,
    required this.number,
    this.lastTime,
  });

  final WorkoutExercise we;
  final int number;

  /// The same set in the previous workout with this exercise.
  final SetLog? lastTime;

  @override
  ConsumerState<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends ConsumerState<_SetRow> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  final _touched = <TextEditingController>{};
  var _busy = false;

  TrackingType get _tracking => widget.we.exercise.tracking;
  SetLog? get _logged => widget.we.logged(widget.number);

  /// The latest earlier set of this exercise logged in this workout, whose
  /// values carry over when there's no target.
  SetLog? get _carry {
    SetLog? best;
    for (final s in widget.we.sets) {
      if (s.setNumber < widget.number &&
          (best == null || s.setNumber > best.setNumber)) {
        best = s;
      }
    }
    return best;
  }

  /// Values to show: what was logged, otherwise a suggestion from the target,
  /// the previous set, or last time.
  (String, String) _values() {
    final l = _logged;
    final tg = widget.we.entry;
    final c = _carry;
    final lt = widget.lastTime;
    String num(double? v) => v == null ? '' : formatNumber(v);
    String dur(int? v) => v == null ? '' : formatDuration(v);
    switch (_tracking) {
      case TrackingType.reps:
        return l != null
            ? (num(l.weightKg), l.reps?.toString() ?? '')
            : (
                num(tg.targetWeightKg ?? c?.weightKg ?? lt?.weightKg),
                (tg.targetReps ?? lt?.reps ?? c?.reps)?.toString() ?? '',
              );
      case TrackingType.time:
        return l != null
            ? (dur(l.durationSec), '')
            : (
                dur(tg.targetDurationSec ?? lt?.durationSec ?? c?.durationSec),
                '',
              );
      case TrackingType.distance:
        return l != null
            ? (num(l.distanceKm), dur(l.durationSec))
            : (
                num(tg.targetDistanceKm ?? lt?.distanceKm ?? c?.distanceKm),
                dur(tg.targetDurationSec ?? lt?.durationSec ?? c?.durationSec),
              );
    }
  }

  void _fill({bool onlyUntouched = false}) {
    final (a, b) = _values();
    if (!onlyUntouched || !_touched.contains(_a)) _a.text = a;
    if (!onlyUntouched || !_touched.contains(_b)) _b.text = b;
  }

  @override
  void initState() {
    super.initState();
    _fill();
    _a.addListener(() => _markTouched(_a));
    _b.addListener(() => _markTouched(_b));
  }

  var _filling = false;

  void _markTouched(TextEditingController c) {
    if (!_filling && _logged == null) _touched.add(c);
  }

  @override
  void didUpdateWidget(_SetRow old) {
    super.didUpdateWidget(old);
    final wasLogged = old.we.logged(old.number);
    final logged = _logged;
    _filling = true;
    if (logged != null && logged != wasLogged) {
      _fill();
    } else if (logged == null) {
      _fill(onlyUntouched: true);
    }
    _filling = false;
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final repo = ref.read(sessionRepoProvider);
    final logged = _logged;
    if (logged != null) {
      setState(() => _busy = true);
      await repo.unlogSet(logged.id);
      // Keep what was entered rather than going back to suggestions.
      _touched.addAll([_a, _b]);
      if (mounted) setState(() => _busy = false);
      return;
    }

    int? reps;
    double? weight;
    int? duration;
    double? distance;
    String? problem;
    switch (_tracking) {
      case TrackingType.reps:
        reps = int.tryParse(_b.text);
        weight = parseDecimal(_a.text);
        if (reps == null || reps <= 0) problem = 'Enter the reps you did';
      case TrackingType.time:
        duration = parseDuration(_a.text);
        if (duration == null || duration <= 0) {
          problem = 'Enter a time like 1:30';
        }
      case TrackingType.distance:
        distance = parseDecimal(_a.text);
        duration = parseDuration(_b.text);
        if (distance == null && duration == null) {
          problem = 'Enter a distance or a time';
        }
    }
    if (problem != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    FocusScope.of(context).unfocus();
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    await repo.logSet(
      entry: widget.we.entry,
      setNumber: widget.number,
      reps: reps,
      weightKg: weight,
      durationSec: duration,
      distanceKm: distance,
    );
    final rest = widget.we.entry.restSec;
    if (rest != null && rest > 0) {
      ref.read(restTimerProvider.notifier).start(rest);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = widget.we.exercise.muscle.color;
    final done = _logged != null;
    final tg = widget.we.entry;
    final target = describeSet(
      _tracking,
      reps: tg.targetReps,
      weightKg: tg.targetWeightKg,
      durationSec: tg.targetDurationSec,
      distanceKm: tg.targetDistanceKm,
    );
    final fields = <Widget>[
      _SetField(
        controller: _a,
        done: done,
        kind: switch (_tracking) {
          TrackingType.reps => _FieldKind.decimal,
          TrackingType.time => _FieldKind.duration,
          TrackingType.distance => _FieldKind.decimal,
        },
      ),
      if (_tracking != TrackingType.time)
        _SetField(
          controller: _b,
          done: done,
          kind: _tracking == TrackingType.reps
              ? _FieldKind.integer
              : _FieldKind.duration,
        ),
    ];

    return AnimatedContainer(
      duration: Motion.medium,
      curve: Motion.standard,
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: done ? color.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: Motion.medium,
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? color : AppColors.surfaceHigh,
            ),
            child: Text(
              '${widget.number}',
              style: t.labelMedium!.copyWith(
                color: done ? onColor(color) : AppColors.textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              target.isEmpty ? '—' : target,
              maxLines: 2,
              style: t.labelMedium!.copyWith(color: AppColors.textTertiary),
            ),
          ),
          for (final f in fields) ...[
            Expanded(child: f),
            const SizedBox(width: 6),
          ],
          SizedBox(
            width: 44,
            height: 40,
            child: Material(
              color: done ? color : AppColors.surfaceHighest,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _toggle,
                child: AnimatedSwitcher(
                  duration: Motion.fast,
                  transitionBuilder: (child, a) =>
                      ScaleTransition(scale: a, child: child),
                  child: Icon(
                    Icons.check_rounded,
                    key: ValueKey(done),
                    color: done ? onColor(color) : AppColors.textTertiary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FieldKind { integer, decimal, duration }

class _SetField extends StatelessWidget {
  const _SetField({
    required this.controller,
    required this.done,
    required this.kind,
  });

  final TextEditingController controller;
  final bool done;
  final _FieldKind kind;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      readOnly: done,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleSmall,
      keyboardType: switch (kind) {
        _FieldKind.integer => TextInputType.number,
        _FieldKind.decimal => const TextInputType.numberWithOptions(
          decimal: true,
        ),
        _FieldKind.duration => TextInputType.datetime,
      },
      inputFormatters: [
        switch (kind) {
          _FieldKind.integer => FilteringTextInputFormatter.digitsOnly,
          _FieldKind.decimal => FilteringTextInputFormatter.allow(
            RegExp(r'[0-9.,]'),
          ),
          _FieldKind.duration => FilteringTextInputFormatter.allow(
            RegExp(r'[0-9:]'),
          ),
        },
      ],
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: done ? Colors.transparent : AppColors.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        hintText: kind == _FieldKind.duration ? 'm:ss' : '–',
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
      ),
    );
  }
}
