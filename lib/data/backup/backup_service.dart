import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/enums.dart';
import '../db/database.dart';
import '../media_paths.dart';

/// Why a backup couldn't be read or restored, in words for the user.
class BackupException implements Exception {
  const BackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What a backup file holds, from its manifest.
class BackupInfo {
  const BackupInfo({
    required this.createdAt,
    required this.schemaVersion,
    required this.profiles,
    required this.workouts,
    required this.measurements,
    required this.mediaFiles,
  });

  factory BackupInfo.fromJson(Map<String, Object?> j) => BackupInfo(
    createdAt: DateTime.parse(j['createdAt']! as String),
    schemaVersion: j['schemaVersion']! as int,
    profiles: [for (final n in j['profiles']! as List) n as String],
    workouts: j['workouts'] as int? ?? 0,
    measurements: j['measurements'] as int? ?? 0,
    mediaFiles: j['mediaFiles'] as int? ?? 0,
  );

  final DateTime createdAt;
  final int schemaVersion;
  final List<String> profiles;
  final int workouts;
  final int measurements;
  final int mediaFiles;
}

/// Current data at a glance, for the backup screen.
class DataStats {
  const DataStats({
    required this.profiles,
    required this.workouts,
    required this.measurements,
    required this.mediaFiles,
    required this.mediaBytes,
  });

  final int profiles;
  final int workouts;
  final int measurements;
  final int mediaFiles;
  final int mediaBytes;
}

/// Writes everything to a single .zip and reads it back.
///
/// A backup holds `backup.json` (what's in it), `fitmeasure.sqlite` (a
/// consistent copy of the database) and, optionally, `media/` with the
/// photos and videos copied into the app.
class BackupService {
  BackupService(
    this._db, {
    Future<Directory> Function()? documents,
    Future<Directory> Function()? temp,
    DateTime Function()? clock,
  }) : _documents = documents ?? getApplicationDocumentsDirectory,
       _temp = temp ?? getTemporaryDirectory,
       _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final Future<Directory> Function() _documents;
  final Future<Directory> Function() _temp;
  final DateTime Function() _now;

  static const _manifestName = 'backup.json';
  static const _dbName = 'fitmeasure.sqlite';
  static const _format = 1;

  Future<Directory> _mediaDir() async =>
      Directory(p.join((await _documents()).path, 'media'));

  Future<File> _restorePoint() async =>
      File(p.join((await _documents()).path, 'backups', 'before-restore.zip'));

  Future<int> _count(TableInfo table) async {
    final c = countAll();
    final row = await (_db.selectOnly(table)..addColumns([c])).getSingle();
    return row.read(c) ?? 0;
  }

  Future<List<File>> _mediaFiles() async {
    final dir = await _mediaDir();
    if (!await dir.exists()) return const [];
    return [
      await for (final e in dir.list(recursive: true))
        if (e is File) e,
    ];
  }

  Future<DataStats> stats() async {
    final files = await _mediaFiles();
    var bytes = 0;
    for (final f in files) {
      bytes += await f.length();
    }
    return DataStats(
      profiles: await _count(_db.profiles),
      workouts: await _count(_db.sessions),
      measurements: await _count(_db.measurements),
      mediaFiles: files.length,
      mediaBytes: bytes,
    );
  }

  String fileNameFor(DateTime at) =>
      'fitmeasure-backup-${DateFormat('yyyy-MM-dd-HHmm').format(at)}.zip';

  /// Writes a backup to the temporary folder and returns it, ready to share
  /// or save. Media is included unless [includeMedia] is false.
  Future<File> export({bool includeMedia = true, String? toPath}) async {
    final now = _now();
    final work = await (await _temp()).createTemp('fitmeasure-export');
    try {
      final dbCopy = File(p.join(work.path, _dbName));
      await _db.customStatement('VACUUM INTO ?', [dbCopy.path]);

      final media = includeMedia ? await _mediaFiles() : const <File>[];
      final mediaRoot = await _mediaDir();
      final profiles = await _db.select(_db.profiles).get();
      final manifest = {
        'app': 'fitmeasure',
        'format': _format,
        'schemaVersion': _db.schemaVersion,
        'createdAt': now.toIso8601String(),
        'profiles': [for (final pr in profiles) pr.name],
        'workouts': await _count(_db.sessions),
        'measurements': await _count(_db.measurements),
        'mediaFiles': media.length,
      };

      final zipPath = toPath ?? p.join((await _temp()).path, fileNameFor(now));
      final zip = ZipFileEncoder()..create(zipPath);
      zip.addArchiveFile(
        ArchiveFile.string(_manifestName, jsonEncode(manifest)),
      );
      await zip.addFile(dbCopy, _dbName);
      for (final f in media) {
        final rel = p.relative(f.path, from: mediaRoot.path);
        // Photos and videos are already compressed; storing is faster.
        await zip.addFile(f, 'media/${p.posix.joinAll(p.split(rel))}', 0);
      }
      await zip.close();
      return File(zipPath);
    } finally {
      await work.delete(recursive: true);
    }
  }

  Archive _open(String path) {
    try {
      return ZipDecoder().decodeStream(InputFileStream(path));
    } catch (_) {
      throw const BackupException('This isn\'t a Fitmeasure backup file.');
    }
  }

  Map<String, Object?> _manifest(Archive archive) {
    final entry = archive.find(_manifestName);
    if (entry == null || archive.find(_dbName) == null) {
      throw const BackupException('This isn\'t a Fitmeasure backup file.');
    }
    try {
      final json = jsonDecode(utf8.decode(entry.readBytes()!));
      if (json is Map<String, Object?> && json['app'] == 'fitmeasure') {
        return json;
      }
    } catch (_) {
      // Falls through to the error below.
    }
    throw const BackupException('This backup file is damaged.');
  }

  /// Reads what a backup holds without changing anything.
  Future<BackupInfo> inspect(String path) async {
    final archive = _open(path);
    try {
      final info = BackupInfo.fromJson(_manifest(archive));
      _checkVersion(info.schemaVersion);
      return info;
    } finally {
      await archive.clear();
    }
  }

  void _checkVersion(int version) {
    if (version > _db.schemaVersion) {
      throw const BackupException(
        'This backup was made by a newer version of Fitmeasure. Update the '
        'app first, then restore it.',
      );
    }
  }

  /// Whether a restore point from before the last restore exists.
  Future<bool> hasRestorePoint() async => (await _restorePoint()).exists();

  /// Undoes the last restore by restoring the data saved just before it.
  Future<void> restoreRestorePoint() async {
    final point = await _restorePoint();
    if (!await point.exists()) {
      throw const BackupException('There\'s no restore point.');
    }
    // Keep it through the restore, which would otherwise replace it.
    final copy = await point.copy('${point.path}.undo');
    try {
      await restore(copy.path, makeRestorePoint: false);
    } finally {
      await copy.delete();
    }
  }

  /// Replaces all data with the backup at [path]. Unless told otherwise, the
  /// current data is first saved as a restore point.
  Future<BackupInfo> restore(
    String path, {
    bool makeRestorePoint = true,
  }) async {
    final archive = _open(path);
    final work = await (await _temp()).createTemp('fitmeasure-restore');
    try {
      final manifest = _manifest(archive);
      final info = BackupInfo.fromJson(manifest);
      _checkVersion(info.schemaVersion);

      final dbCopy = File(p.join(work.path, _dbName));
      final out = OutputFileStream(dbCopy.path);
      archive.find(_dbName)!.writeContent(out);
      await out.close();

      if (makeRestorePoint) {
        final point = await _restorePoint();
        await point.parent.create(recursive: true);
        await export(includeMedia: true, toPath: point.path);
      }

      await _copyRows(dbCopy.path);
      await _restoreMedia(archive);
      _db.markTablesUpdated(_db.allTables);
      return info;
    } finally {
      await archive.clear();
      await work.delete(recursive: true);
    }
  }

  /// Copies every table from the backup database into this one, replacing
  /// what's there. Columns are matched by name, so backups from older
  /// versions (with fewer tables or columns) restore too.
  Future<void> _copyRows(String backupPath) async {
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.customStatement('ATTACH DATABASE ? AS backup', [backupPath]);
    } on Exception {
      await _db.customStatement('PRAGMA foreign_keys = ON');
      throw const BackupException('This backup file is damaged.');
    }
    try {
      final backupTables = {
        for (final r
            in await _db
                .customSelect(
                  "SELECT name FROM backup.sqlite_master WHERE type = 'table'",
                )
                .get())
          r.read<String>('name'),
      };
      if (!backupTables.contains(_db.profiles.actualTableName)) {
        throw const BackupException('This backup file is damaged.');
      }
      await _db.transaction(() async {
        for (final table in _db.allTables) {
          final name = table.actualTableName;
          await _db.customStatement('DELETE FROM main."$name"');
          if (!backupTables.contains(name)) continue;
          final backupColumns = {
            for (final r
                in await _db
                    .customSelect('PRAGMA backup.table_info("$name")')
                    .get())
              r.read<String>('name'),
          };
          final columns = [
            for (final c in table.$columns)
              if (backupColumns.contains(c.name)) '"${c.name}"',
          ].join(', ');
          await _db.customStatement(
            'INSERT INTO main."$name" ($columns) '
            'SELECT $columns FROM backup."$name"',
          );
        }
      });
    } on BackupException {
      rethrow;
    } on Exception {
      throw const BackupException(
        'This backup couldn\'t be restored. Your data wasn\'t changed.',
      );
    } finally {
      await _db.customStatement('DETACH DATABASE backup');
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// Replaces the media folder with the backup's. Media paths are made
  /// relative (older backups stored absolute ones), and rows whose file
  /// isn't there are dropped.
  Future<void> _restoreMedia(Archive archive) async {
    final root = await _mediaDir();
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);

    for (final entry in archive) {
      if (!entry.isFile || !entry.name.startsWith('media/')) continue;
      final parts = entry.name.substring('media/'.length).split('/');
      // Only plain relative paths inside media/.
      if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) continue;
      final file = File(p.joinAll([root.path, ...parts]));
      if (!p.isWithin(root.path, file.path)) continue;
      await file.parent.create(recursive: true);
      final out = OutputFileStream(file.path);
      entry.writeContent(out);
      await out.close();
    }

    await _db.customStatement(relativizeMediaPathsSql);
    final documents = (await _documents()).path;
    final media = await (_db.select(
      _db.exerciseMedia,
    )..where((m) => m.kind.equalsValue(MediaKind.link).not())).get();
    for (final m in media) {
      if (!await File(resolveMediaPath(documents, m.uri)).exists()) {
        await (_db.delete(
          _db.exerciseMedia,
        )..where((t) => t.id.equals(m.id))).go();
      }
    }
  }
}
