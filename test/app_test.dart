import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fitmeasure/app/app.dart';
import 'package:fitmeasure/app/providers.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/features/cycles/cycle_editor_screen.dart';
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
    expect(find.text('Start a cycle'), findsOneWidget);

    // Start a cycle with the defaults.
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
}
