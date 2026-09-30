import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitmeasure/data/backup/backup_service.dart';
import 'package:fitmeasure/data/db/database.dart';
import 'package:fitmeasure/data/repos/exercise_repo.dart';
import 'package:fitmeasure/data/repos/measurement_repo.dart';
import 'package:fitmeasure/data/repos/profile_repo.dart';
import 'package:fitmeasure/data/repos/session_repo.dart';
import 'package:fitmeasure/data/repos/settings_repo.dart';
import 'package:fitmeasure/domain/enums.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _memoryDb() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

void main() {
  // These tests open two databases at once on purpose: two phones.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory root;
  late Directory docsA;
  late Directory docsB;
  late Directory temp;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fitmeasure_backup');
    docsA = await Directory('${root.path}/phoneA').create();
    docsB = await Directory('${root.path}/phoneB').create();
    temp = await Directory('${root.path}/tmp').create();
  });

  tearDown(() => root.delete(recursive: true));

  BackupService service(AppDatabase db, Directory docs) =>
      BackupService(db, documents: () async => docs, temp: () async => temp);

  /// A profile with a workout, a measurement and a photo.
  Future<void> seed(AppDatabase db, Directory docs) async {
    final pid = await ProfileRepo(
      db,
      mediaRoot: () async => docs,
    ).create(name: 'Ada', color: 1);
    final bench = await (db.select(
      db.exercises,
    )..where((e) => e.name.equals('Bench Press'))).getSingle();
    final sessions = SessionRepo(db);
    final s = await sessions.start(profileId: pid, name: 'Push');
    await sessions.addExercises(s, [bench]);
    final entry = (await sessions.loadWorkout(s))!.exercises.single.entry;
    await sessions.logSet(entry: entry, setNumber: 1, reps: 5, weightKg: 80);
    await sessions.finish(s);
    final weight = (await MeasurementRepo(db).watchAll(pid).first).first;
    await MeasurementRepo(db).logMany(pid, {weight.type.id: 82.5});
    await ExerciseRepo(db, mediaRoot: () async => docs).addFile(
      exerciseId: bench.id,
      profileId: pid,
      fileName: 'form.jpg',
      bytes: Stream.value([1, 2, 3, 4]),
    );
  }

  test('a backup restores everything on another phone', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final stats = await service(a, docsA).stats();
    expect(stats.workouts, 1);
    expect(stats.mediaFiles, 1);

    final zip = await service(a, docsA).export();
    final info = await service(a, docsA).inspect(zip.path);
    expect(info.profiles, ['Ada']);
    expect(info.workouts, 1);
    expect(info.measurements, 1);
    expect(info.mediaFiles, 1);

    // A different phone with its own, different data.
    final b = _memoryDb();
    addTearDown(b.close);
    await ProfileRepo(b).create(name: 'Someone else', color: 2);
    final restored = await service(b, docsB).restore(zip.path);
    expect(restored.profiles, ['Ada']);

    expect([for (final p in await b.select(b.profiles).get()) p.name], ['Ada']);
    final logs = await b.select(b.setLogs).get();
    expect(logs.single.weightKg, 80);
    expect((await b.select(b.measurements).get()).single.value, 82.5);
    // The built-in library isn't duplicated.
    expect(
      await b.select(b.exercises).get(),
      hasLength((await a.select(a.exercises).get()).length),
    );
    final media = (await b.select(b.exerciseMedia).get()).single;
    expect(media.uri, startsWith(docsB.path));
    expect(await File(media.uri).readAsBytes(), [1, 2, 3, 4]);
  });

  test('restoring notifies live queries', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final zip = await service(a, docsA).export();

    final b = _memoryDb();
    addTearDown(b.close);
    final names = <List<String>>[];
    final sub = b
        .select(b.profiles)
        .watch()
        .map((ps) => [for (final p in ps) p.name])
        .listen(names.add);
    await pumpEventQueue();
    await service(b, docsB).restore(zip.path);
    await pumpEventQueue();
    await sub.cancel();
    expect(names.first, isEmpty);
    expect(names.last, ['Ada']);
  });

  test('a backup without media drops the media entries', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final zip = await service(a, docsA).export(includeMedia: false);
    expect((await service(a, docsA).inspect(zip.path)).mediaFiles, 0);

    final b = _memoryDb();
    addTearDown(b.close);
    await service(b, docsB).restore(zip.path);
    expect(await b.select(b.exerciseMedia).get(), isEmpty);
    expect(await b.select(b.setLogs).get(), hasLength(1));
  });

  test('a restore can be undone with the restore point', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final zip = await service(a, docsA).export();

    final b = _memoryDb();
    addTearDown(b.close);
    await ProfileRepo(b).create(name: 'Original', color: 2);
    await SettingsRepo(b).setBool(SettingsRepo.keepAwake, false);
    final svc = service(b, docsB);
    expect(await svc.hasRestorePoint(), isFalse);
    await svc.restore(zip.path);
    expect(await svc.hasRestorePoint(), isTrue);
    expect((await b.select(b.profiles).get()).single.name, 'Ada');

    await svc.restoreRestorePoint();
    expect((await b.select(b.profiles).get()).single.name, 'Original');
    expect(await SettingsRepo(b).getBool(SettingsRepo.keepAwake), isFalse);
  });

  test('files that aren\'t backups are refused without changes', () async {
    final b = _memoryDb();
    addTearDown(b.close);
    await ProfileRepo(b).create(name: 'Keep me', color: 2);
    final svc = service(b, docsB);

    final text = await File('${temp.path}/notes.zip').writeAsString('hello');
    await expectLater(svc.restore(text.path), throwsA(isA<BackupException>()));

    final other = '${temp.path}/other.zip';
    final zip = ZipFileEncoder()..create(other);
    zip.addArchiveFile(ArchiveFile.string('readme.txt', 'hi'));
    await zip.close();
    await expectLater(svc.inspect(other), throwsA(isA<BackupException>()));

    expect((await b.select(b.profiles).get()).single.name, 'Keep me');
  });

  test('backups from a newer app version are refused', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final zip = await service(a, docsA).export();

    // Rewrite the manifest to claim a future schema.
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final manifest = jsonDecode(
      utf8.decode(archive.find('backup.json')!.readBytes()!),
    ) as Map<String, Object?>;
    manifest['schemaVersion'] = a.schemaVersion + 1;
    final future = '${temp.path}/future.zip';
    final out = ZipFileEncoder()..create(future);
    for (final f in archive) {
      out.addArchiveFile(
        f.name == 'backup.json'
            ? ArchiveFile.string('backup.json', jsonEncode(manifest))
            : ArchiveFile.bytes(f.name, f.readBytes()!),
      );
    }
    await out.close();

    final b = _memoryDb();
    addTearDown(b.close);
    await expectLater(
      service(b, docsB).inspect(future),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        ),
      ),
    );
  });

  test('media entries can\'t escape the media folder', () async {
    final a = _memoryDb();
    addTearDown(a.close);
    await seed(a, docsA);
    final zip = await service(a, docsA).export();
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final evil = '${temp.path}/evil.zip';
    final out = ZipFileEncoder()..create(evil);
    for (final f in archive) {
      out.addArchiveFile(ArchiveFile.bytes(f.name, f.readBytes()!));
    }
    out.addArchiveFile(ArchiveFile.string('media/../../escaped.txt', 'x'));
    await out.close();

    final b = _memoryDb();
    addTearDown(b.close);
    await service(b, docsB).restore(evil);
    expect(await File('${root.path}/escaped.txt').exists(), isFalse);
    expect(await File('${docsB.path}/escaped.txt').exists(), isFalse);
    expect(MediaKind.values, isNotEmpty);
  });
}
