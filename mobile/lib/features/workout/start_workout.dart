import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repos/plan_repo.dart';
import 'workout_screen.dart';

void openWorkout(BuildContext context, int sessionId) =>
    _open(Navigator.of(context), sessionId);

void _open(NavigatorState navigator, int sessionId) => navigator.push(
  MaterialPageRoute(builder: (_) => WorkoutScreen(sessionId: sessionId)),
);

/// Starts a workout for [day] (or an empty one) and opens it. Only one
/// workout runs at a time, so an unfinished one is reopened instead. An
/// empty workout's clock waits until the person taps Start, so they can
/// add exercises first.
Future<void> startWorkout(
  BuildContext context,
  WidgetRef ref, {
  PlanDayDetail? day,
}) async {
  final profileId = ref.read(currentProfileIdProvider);
  if (profileId == null) return;
  // Starting a workout rebuilds Today (it gains a resume card), which can
  // unmount [context], so hold on to what's needed before any await.
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(sessionRepoProvider);
  final cycleId = ref.read(activeCycleProvider)?.id;
  final running = await repo.active(profileId);
  if (running != null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Finish or discard this workout before starting another'),
      ),
    );
    _open(navigator, running.id);
    return;
  }
  final id = await repo.start(
    profileId: profileId,
    name: day?.day.name ?? 'Workout',
    planDayId: day?.day.id,
    cycleId: cycleId,
    startNow: day != null,
  );
  if (navigator.mounted) _open(navigator, id);
}
