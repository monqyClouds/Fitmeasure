import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/enums.dart';
import '../db/database.dart';
import '../media_paths.dart';

class ExerciseWithMedia {
  const ExerciseWithMedia(this.exercise, this.mediaCount);
  final Exercise exercise;
  final int mediaCount;
}

class ExerciseRepo {
  ExerciseRepo(this._db, {Future<Directory> Function()? mediaRoot})
    : _mediaRoot = mediaRoot ?? getApplicationDocumentsDirectory;
  final AppDatabase _db;
  final Future<Directory> Function() _mediaRoot;

  /// Built-in exercises plus this profile's custom ones, with how many media
  /// items this profile has attached to each.
  Stream<List<ExerciseWithMedia>> watchLibrary(int profileId) {
    final count = _db.exerciseMedia.id.count();
    final query =
        _db.select(_db.exercises).join([
            leftOuterJoin(
              _db.exerciseMedia,
              _db.exerciseMedia.exerciseId.equalsExp(_db.exercises.id) &
                  _db.exerciseMedia.profileId.equals(profileId),
              useColumns: false,
            ),
          ])
          ..addColumns([count])
          ..where(
            _db.exercises.profileId.isNull() |
                _db.exercises.profileId.equals(profileId),
          )
          ..groupBy([_db.exercises.id])
          ..orderBy([
            OrderingTerm.asc(_db.exercises.name.collate(Collate.noCase)),
          ]);
    return query.watch().map(
      (rows) => [
        for (final r in rows)
          ExerciseWithMedia(r.readTable(_db.exercises), r.read(count) ?? 0),
      ],
    );
  }

  Stream<Exercise?> watch(int id) => (_db.select(
    _db.exercises,
  )..where((e) => e.id.equals(id))).watchSingleOrNull();

  Future<int> saveCustom({
    int? id,
    required int profileId,
    required String name,
    required MuscleGroup muscle,
    required Equipment equipment,
    required TrackingType tracking,
    String? notes,
  }) async {
    final companion = ExercisesCompanion(
      profileId: Value(profileId),
      name: Value(name.trim()),
      muscle: Value(muscle),
      equipment: Value(equipment),
      tracking: Value(tracking),
      notes: Value(notes?.trim().isEmpty ?? true ? null : notes!.trim()),
    );
    if (id == null) return _db.into(_db.exercises).insert(companion);
    await (_db.update(
      _db.exercises,
    )..where((e) => e.id.equals(id))).write(companion);
    return id;
  }

  Future<void> deleteCustom(int id) async {
    final media = await (_db.select(
      _db.exerciseMedia,
    )..where((m) => m.exerciseId.equals(id))).get();
    await (_db.delete(
      _db.exercises,
    )..where((e) => e.id.equals(id) & e.profileId.isNotNull())).go();
    for (final m in media) {
      await _deleteFile(m);
    }
  }

  // --- Media ---------------------------------------------------------------

  Stream<List<MediaItem>> watchMedia(int exerciseId, int profileId) =>
      (_db.select(_db.exerciseMedia)
            ..where(
              (m) =>
                  m.exerciseId.equals(exerciseId) &
                  m.profileId.equals(profileId),
            )
            ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
          .watch();

  /// Copies a picked file into the app's own storage, so the reference keeps
  /// working even if the original is moved or deleted.
  Future<void> addFile({
    required int exerciseId,
    required int profileId,
    required String fileName,
    required Stream<List<int>> bytes,
  }) async {
    final root = await _mediaRoot();
    final dir = Directory(p.join(root.path, 'media', '$profileId'));
    await dir.create(recursive: true);
    final ext = p.extension(fileName).toLowerCase();
    final dest = File(
      p.join(
        dir.path,
        '${exerciseId}_${DateTime.now().microsecondsSinceEpoch}$ext',
      ),
    );
    await bytes.pipe(dest.openWrite());
    await _db
        .into(_db.exerciseMedia)
        .insert(
          ExerciseMediaCompanion.insert(
            profileId: profileId,
            exerciseId: exerciseId,
            kind: kindForExtension(ext),
            uri: p.relative(dest.path, from: root.path),
            label: Value(p.basenameWithoutExtension(fileName)),
          ),
        );
  }

  Future<void> addLink({
    required int exerciseId,
    required int profileId,
    required String url,
    String? label,
  }) => _db
      .into(_db.exerciseMedia)
      .insert(
        ExerciseMediaCompanion.insert(
          profileId: profileId,
          exerciseId: exerciseId,
          kind: MediaKind.link,
          uri: url.trim(),
          label: Value(label?.trim().isEmpty ?? true ? null : label!.trim()),
        ),
      );

  Future<void> deleteMedia(MediaItem item) async {
    await (_db.delete(
      _db.exerciseMedia,
    )..where((m) => m.id.equals(item.id))).go();
    await _deleteFile(item);
  }

  Future<void> _deleteFile(MediaItem item) async {
    if (item.kind == MediaKind.link) return;
    final f = File(resolveMediaPath((await _mediaRoot()).path, item.uri));
    if (await f.exists()) await f.delete();
  }

  static const _videoExtensions = {
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mkv',
    '.3gp',
    '.avi',
  };

  static MediaKind kindForExtension(String ext) =>
      _videoExtensions.contains(ext.toLowerCase())
      ? MediaKind.video
      : MediaKind.image;
}
