import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'room_client.dart';

/// A room on the live server: created by someone, joined by its ID. The
/// server keeps the name; the ID is what's shared.
class LiveRoom {
  const LiveRoom({
    required this.id,
    required this.name,
    this.hostKey,
    this.people,
    this.lastJoined,
  });

  final String id;
  final String name;

  /// Given to whoever created the room: joining with it makes them host.
  final String? hostKey;

  /// How many are in it, when it was looked up.
  final int? people;
  final DateTime? lastJoined;

  bool get created => hostKey != null;

  /// What to share: opens the app if it's installed, else the web room.
  Uri get link => liveServer.replace(path: '/r/$id');

  /// The ID as shown and read out: "k7f 3qz".
  String get displayId => '${id.substring(0, 3)} ${id.substring(3)}';

  LiveRoom copyWith({String? name, String? hostKey, DateTime? lastJoined}) =>
      LiveRoom(
        id: id,
        name: name ?? this.name,
        hostKey: hostKey ?? this.hostKey,
        people: people,
        lastJoined: lastJoined ?? this.lastJoined,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (hostKey != null) 'hostKey': hostKey,
    if (lastJoined != null) 'lastJoined': lastJoined!.toIso8601String(),
  };

  factory LiveRoom.fromJson(Map<String, Object?> j) => LiveRoom(
    id: j['id']! as String,
    name: j['name']! as String,
    hostKey: j['hostKey'] as String?,
    people: (j['people'] as num?)?.toInt(),
    lastJoined: j['lastJoined'] == null
        ? null
        : DateTime.tryParse(j['lastJoined']! as String),
  );
}

/// Characters room IDs are made of: no 0/o or 1/l/i, which are easily
/// mistaken for each other.
const _idAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

/// What someone typed or pasted (" K7F-3QZ ", or a link, or a message with
/// a link in it) as a room ID, or null if it can't be one.
String? normalizeRoomId(String text) {
  var s = text.trim();
  final at = s.lastIndexOf('/r/');
  if (at >= 0) {
    s = s.substring(at + 3).split(RegExp(r'[/?#\s]')).first;
  }
  s = s.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
  if (s.length != 6 || s.split('').any((c) => !_idAlphabet.contains(c))) {
    return null;
  }
  return s;
}

/// The room ID in a room link (https://live.somto.si/r/k7f3qz), or null.
String? roomIdFromLink(Uri uri) {
  final s = uri.pathSegments;
  if (s.length < 2 || s[0] != 'r') return null;
  return normalizeRoomId(s[1]);
}

/// Something the server said no to, in words to show.
class RoomsApiException implements Exception {
  const RoomsApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Creates and looks up rooms on the live server.
class RoomsApi {
  const RoomsApi();

  /// Creates a room called [name]. We get its host key: keep it.
  Future<LiveRoom> create(String name) async {
    final (status, body) = await request(
      'POST',
      '/api/rooms',
      body: {'name': name},
    );
    if (status != 201) throw RoomsApiException(error(body));
    return LiveRoom.fromJson(body);
  }

  /// The room with [id], or null if there's none.
  Future<LiveRoom?> find(String id) async {
    final (status, body) = await request('GET', '/api/rooms/$id');
    if (status == 404) return null;
    if (status != 200) throw RoomsApiException(error(body));
    return LiveRoom.fromJson(body);
  }

  static String error(Map<String, Object?> body) =>
      body['error'] as String? ?? 'Something went wrong on the server';

  /// A JSON request to the live server: its status and JSON body. Throws a
  /// RoomsApiException, in words to show, when the server can't be reached.
  static Future<(int, Map<String, Object?>)> request(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.openUrl(method, liveServer.replace(path: path));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      final json = text.isEmpty ? null : jsonDecode(text);
      return (
        res.statusCode,
        json is Map<String, Object?> ? json : <String, Object?>{},
      );
    } on SocketException {
      throw const RoomsApiException("Couldn't reach the server");
    } on TimeoutException {
      throw const RoomsApiException("Couldn't reach the server");
    } on FormatException {
      throw const RoomsApiException('The server sent something unexpected');
    } finally {
      client.close(force: true);
    }
  }
}
