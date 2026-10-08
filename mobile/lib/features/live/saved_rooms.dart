import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repos/settings_repo.dart';
import 'rooms_api.dart';

/// The rooms this phone created or joined, newest first, so they're one
/// tap away. Created rooms keep their host key here: it's what makes us
/// their host.
class SavedRooms {
  SavedRooms(this._settings);
  final SettingsRepo _settings;

  static const _key = 'live_rooms';

  /// How many are kept.
  static const max = 20;

  Stream<List<LiveRoom>> watch() => _settings.watchString(_key).map(_decode);

  Future<List<LiveRoom>> load() async =>
      _decode(await _settings.getString(_key));

  /// The saved room with [id], if any.
  Future<LiveRoom?> find(String id) async {
    for (final r in await load()) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Saves [room] as just joined, keeping a host key we already had and
  /// taking the server's name for it.
  Future<LiveRoom> remember(LiveRoom room, {DateTime? now}) async {
    final rooms = await load();
    final old = rooms.where((r) => r.id == room.id).firstOrNull;
    final saved = room.copyWith(
      hostKey: room.hostKey ?? old?.hostKey,
      lastJoined: now ?? DateTime.now(),
    );
    final updated = [saved, ...rooms.where((r) => r.id != room.id)];
    // Rooms we created are worth more than ones we only visited.
    while (updated.length > max) {
      final i = updated.lastIndexWhere((r) => !r.created);
      updated.removeAt(i < 0 ? updated.length - 1 : i);
    }
    await _save(updated);
    return saved;
  }

  Future<void> forget(String id) async => _save([
    for (final r in await load())
      if (r.id != id) r,
  ]);

  Future<void> _save(List<LiveRoom> rooms) => _settings.setString(
    _key,
    jsonEncode([for (final r in rooms) r.toJson()]),
  );

  static List<LiveRoom> _decode(String? json) {
    if (json == null) return const [];
    try {
      return [
        for (final r in jsonDecode(json) as List)
          LiveRoom.fromJson((r as Map).cast<String, Object?>()),
      ];
    } on Object {
      return const [];
    }
  }
}

final savedRoomsProvider = Provider(
  (ref) => SavedRooms(ref.watch(settingsRepoProvider)),
);

final savedRoomsListProvider = StreamProvider.autoDispose<List<LiveRoom>>(
  (ref) => ref.watch(savedRoomsProvider).watch(),
);

final roomsApiProvider = Provider((ref) => const RoomsApi());
