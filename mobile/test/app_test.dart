import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fitmeasure/app/app.dart';
import 'package:fitmeasure/app/providers.dart';
import 'package:fitmeasure/data/backup/backup_service.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/repos/settings_repo.dart';
import 'package:fitmeasure/features/cycles/cycle_editor_screen.dart';
import 'package:fitmeasure/features/progress/exercise_progress_screen.dart';
import 'package:fitmeasure/features/settings/settings_screen.dart';
import 'package:fitmeasure/features/workout/workout_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first run: create a profile, land on Today, browse library', (
    tester,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const FitmeasureApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Create your profile'), findsOneWidget);
    await tester.tap(find.text('Create your profile'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Sam');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Sam'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Plan your training'), findsOneWidget);

    // Start a cycle with the defaults.
    await tester.scrollUntilVisible(find.text('Start a cycle'), 200);
    await tester.tap(find.text('Start a cycle'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Start cycle'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CycleEditorScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Start cycle'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Week '), 200);
    expect(find.text('Week '), findsOneWidget);
    expect(find.textContaining('of 12'), findsOneWidget);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bench');
    await tester.pumpAndSettle();
    expect(find.text('Bench Press'), findsOneWidget);

    await tester.tap(find.text('Bench Press'));
    await tester.pumpAndSettle();
    expect(find.text('Add a form video or photo'), findsOneWidget);
  });

  testWidgets('an empty workout waits for Start', (tester) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);
    final pid = await ProfileRepo(db).create(name: 'Sam', color: 0xFFB8F34A);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container.read(currentProfileIdProvider.notifier).select(pid);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FitmeasureApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Start an empty workout'), 200);
    await tester.ensureVisible(find.text('Start an empty workout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start an empty workout'));
    // The play button pulses, so pump rather than settle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(WorkoutScreen), findsOneWidget);
    expect(find.text('READY WHEN YOU ARE'), findsOneWidget);
    expect(find.text('Finish workout'), findsNothing);

    await tester.tap(find.text('Start workout'));
    await tester.pumpAndSettle();
    expect(find.text('READY WHEN YOU ARE'), findsNothing);
    expect((await db.select(db.sessions).getSingle()).started, isTrue);
  });

  testWidgets('plan from a template, log a set, finish the workout', (
    tester,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);
    final pid = await ProfileRepo(db).create(name: 'Sam', color: 0xFFB8F34A);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container.read(currentProfileIdProvider.notifier).select(pid);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FitmeasureApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Pick the Push / Pull / Legs template on the Plans tab.
    await tester.tap(find.text('Plans'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Push / Pull / Legs'));
    await tester.pumpAndSettle();
    expect(find.text('Follow this plan on Today'), findsNothing); // active
    expect(find.text('Push'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Today offers the first day of the rotation.
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Start workout'), 200);
    await tester.ensureVisible(find.text('Start workout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start workout'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkoutScreen), findsOneWidget);
    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('of 15 sets'), findsOneWidget);

    // Tick off the first set; its reps are prefilled from the target.
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    // The rest countdown animates continuously, so pump rather than settle.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Resting'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    await tester.tap(find.byTooltip('Skip rest'));
    await tester.pumpAndSettle();
    expect(find.text('Resting'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Finish workout'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.ensureVisible(find.text('Finish workout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish workout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text('Workout complete'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Today now shows the day as done, and the workout in history.
    expect(find.text('Train it again'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('RECENT WORKOUTS'), 200);
    expect(find.text('RECENT WORKOUTS'), findsOneWidget);

    // The bench press now has a strength chart and records.
    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Bench Press'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    // Centre it, clear of the top edge.
    Scrollable.ensureVisible(
      tester.element(find.text('Bench Press')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bench Press'));
    await tester.pumpAndSettle();
    expect(find.byType(ExerciseProgressScreen), findsOneWidget);
    expect(find.text('ESTIMATED 1-REP MAX'), findsNothing); // bodyweight set
    expect(find.text('PERSONAL RECORDS'), findsOneWidget);
  });

  testWidgets('log body weight from Today and see it on Progress', (
    tester,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);
    final pid = await ProfileRepo(db).create(name: 'Sam', color: 0xFF5AA9FF);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container.read(currentProfileIdProvider.notifier).select(pid);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FitmeasureApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Body weight'), findsOneWidget);
    await tester.tap(find.byTooltip('Log body weight'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '82,5');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('82.5 kg'), findsOneWidget);
    expect(find.byTooltip('Log body weight'), findsNothing); // done today

    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();
    expect(find.text('82.5 kg'), findsOneWidget);
    expect(find.text('BODY'), findsOneWidget);
  });

  testWidgets('settings: backup summary and keep-screen-on switch', (
    tester,
  ) async {
    final db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(db.close);
    final pid = await ProfileRepo(db).create(name: 'Sam', color: 0xFFB8F34A);
    // Plugins for app folders don't exist in tests; use a temp folder.
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('fitmeasure_settings'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backupServiceProvider.overrideWithValue(
          BackupService(db, documents: () async => dir, temp: () async => dir),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(currentProfileIdProvider.notifier).select(pid);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FitmeasureApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The avatar opens the profile menu.
    await tester.tap(find.text('S').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings & backup'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Back up'), findsOneWidget);
    // The stats read files, which needs real (not fake) time to finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('people'), findsOneWidget);
    expect(find.text('Undo last restore'), findsNothing);

    final repo = SettingsRepo(db);
    expect(await repo.getBool(SettingsRepo.keepAwake, fallback: true), isTrue);
    await tester.scrollUntilVisible(find.text('Keep screen on'), 200);
    await tester.tap(find.text('Keep screen on'));
    await tester.pumpAndSettle();
    expect(await repo.getBool(SettingsRepo.keepAwake, fallback: true), isFalse);
  });
}
