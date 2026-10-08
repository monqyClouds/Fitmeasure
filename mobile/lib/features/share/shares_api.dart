import '../../data/sharing.dart';
import '../live/room_client.dart';
import '../live/rooms_api.dart';

/// Characters share IDs are made of, as room IDs.
const _idAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

/// The share ID in a share link (https://live.somto.si/s/k7f3qz2m), or null.
String? shareIdFromLink(Uri uri) {
  final s = uri.pathSegments;
  if (s.length < 2 || s[0] != 's') return null;
  final id = s[1].toLowerCase();
  if (id.length != 8 || id.split('').any((c) => !_idAlphabet.contains(c))) {
    return null;
  }
  return id;
}

/// Puts shares on the live server and fetches them.
class SharesApi {
  const SharesApi();

  /// Shares [share] and returns its link.
  Future<Uri> create(ShareContent share) async {
    final (status, body) = await RoomsApi.request(
      'POST',
      '/api/shares',
      body: share.toJson(),
    );
    if (status != 201) throw RoomsApiException(RoomsApi.error(body));
    return Uri.parse(body['link']! as String);
  }

  /// The share with [id], or null if there's none (or it's from a newer
  /// app).
  Future<ShareContent?> find(String id) async {
    final (status, body) = await RoomsApi.request('GET', '/api/shares/$id');
    if (status == 404) return null;
    if (status != 200) throw RoomsApiException(RoomsApi.error(body));
    return ShareContent.fromJson(body);
  }

  /// The link for a share ID.
  static Uri link(String id) => liveServer.replace(path: '/s/$id');
}
