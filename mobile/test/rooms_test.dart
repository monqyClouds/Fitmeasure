import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/app/app.dart';
import 'package:fitmeasure/app/providers.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/features/shell/home_shell.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/repos/settings_repo.dart';
import 'package:fitmeasure/features/live/rooms_api.dart';
import 'package:fitmeasure/features/live/saved_rooms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase memoryDb() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

void main() {
  test('room IDs come out of whatever was typed or pasted', () {
    for (final (input, want) in [
      ('k7f3qz', 'k7f3qz'),
      (' K7F 3QZ ', 'k7f3qz'),
      ('k7f-3qz', 'k7f3qz'),
      ('https://live.somto.si/r/k7f3qz', 'k7f3qz'),
      ('Train with me: https://live.somto.si/r/K7F3QZ\nOr enter…', 'k7f3qz'),
      ('k7f3q', null),
      ('k0f3qz', null), // 0 is never used
      ('gym', null),
    ]) {
      expect(normalizeRoomId(input), want, reason: input);
    }
    expect(
      roomIdFromLink(Uri.parse('https://live.somto.si/r/k7f3qz')),
      'k7f3qz',
    );
    expect(roomIdFromLink(Uri.parse('https://live.somto.si/room/')), isNull);
  });

  test('a room shows its ID in two halves, and links to itself', () {
    const r = LiveRoom(id: 'k7f3qz', name: 'Tuesday HIIT');
    expect(r.displayId, 'k7f 3qz');
    expect(r.link.path, '/r/k7f3qz');
    expect(r.created, isFalse);
  });

  group('saved rooms', () {
    late AppDatabase db;
    late SavedRooms saved;
    final t0 = DateTime(2026, 10, 8, 12);

    setUp(() {
      db = memoryDb();
      saved = SavedRooms(SettingsRepo(db));
    });
    tearDown(() => db.close());

    test(
      'newest first, keeping the host key and taking the new name',
      () async {
        await saved.remember(
          const LiveRoom(id: 'aaaaaa', name: 'Mine', hostKey: 'secret'),
          now: t0,
        );
        await saved.remember(
          const LiveRoom(id: 'bbbbbb', name: 'Theirs'),
          now: t0.add(const Duration(minutes: 1)),
        );
        // Looked up again: the server's copy has a new name and no host key.
        await saved.remember(
          const LiveRoom(id: 'aaaaaa', name: 'Mine, renamed'),
          now: t0.add(const Duration(minutes: 2)),
        );
        final rooms = await saved.load();
        expect(rooms.map((r) => r.id), ['aaaaaa', 'bbbbbb']);
        expect(rooms.first.name, 'Mine, renamed');
        expect(rooms.first.hostKey, 'secret');
        expect(rooms.first.lastJoined, t0.add(const Duration(minutes: 2)));
      },
    );

    test('only the latest are kept, rooms we created before others', () async {
      await saved.remember(
        const LiveRoom(id: 'hhhhhh', name: 'Mine', hostKey: 'k'),
        now: t0,
      );
      for (var i = 0; i < SavedRooms.max; i++) {
        await saved.remember(
          LiveRoom(id: 'v$i'.padRight(6, 'x'), name: 'Visit $i'),
          now: t0.add(Duration(minutes: i + 1)),
        );
      }
      final rooms = await saved.load();
      expect(rooms, hasLength(SavedRooms.max));
      expect(rooms.any((r) => r.id == 'hhhhhh'), isTrue);
    });

    test('forgetting', () async {
      await saved.remember(const LiveRoom(id: 'aaaaaa', name: 'A'));
      await saved.forget('aaaaaa');
      expect(await saved.load(), isEmpty);
    });
  });

  testWidgets('Live tab: join by ID, and your rooms', (tester) async {
    final db = memoryDb();
    addTearDown(db.close);
    final pid = await ProfileRepo(db).create(name: 'Sam', color: 0xFFB8F34A);
    await SavedRooms(SettingsRepo(db)).remember(
      const LiveRoom(id: 'k7f3qz', name: 'Tuesday HIIT', hostKey: 'secret'),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        roomLinksProvider.overrideWithValue(const Stream.empty()),
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
    await tester.tap(find.text('Live'));
    // The illustration pulses, so pump rather than settle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final join = find.widgetWithText(FilledButton, 'Join room');
    expect(tester.widget<FilledButton>(join).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'k7f-3qz');
    await tester.pump();
    expect(tester.widget<FilledButton>(join).onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), 'gym-room');
    await tester.pump();
    expect(find.text('Room IDs have six letters and digits'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Tuesday HIIT'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('K7F 3QZ  ·  You host'), findsOneWidget);
  });
}
