import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a video link points at, worked out from the URL alone.
abstract final class VideoLink {
  static final _youTubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// The YouTube video ID in [url] (watch, youtu.be, shorts, embed, live and
  /// mobile links), or null if it isn't a YouTube video.
  static String? youTubeId(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final host = uri.host.toLowerCase().replaceFirst(
      RegExp(r'^(www|m|music)\.'),
      '',
    );
    String? id;
    if (host == 'youtu.be') {
      id = uri.pathSegments.firstOrNull;
    } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
      final s = uri.pathSegments;
      if (s.firstOrNull == 'watch') {
        id = uri.queryParameters['v'];
      } else if (s.length >= 2 &&
          const {'shorts', 'embed', 'live', 'v'}.contains(s[0])) {
        id = s[1];
      }
    }
    return id != null && _youTubeId.hasMatch(id) ? id : null;
  }

  /// YouTube's own still for a video; there's always one.
  static String youTubeThumb(String id) =>
      'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  static const _videoExtensions = {'.mp4', '.m4v', '.mov', '.webm', '.m3u8'};

  /// Whether [url] is a video file the app's own player can play.
  static bool isDirectVideo(String url) {
    final path = Uri.tryParse(url.trim())?.path.toLowerCase() ?? '';
    return _videoExtensions.any(path.endsWith);
  }

  /// Whether the app plays [url] itself rather than handing it to another
  /// app (Instagram and TikTok, for example, don't allow embedding).
  static bool playsInApp(String url) =>
      youTubeId(url) != null || isDirectVideo(url);

  /// A short name for where [url] is from: "YouTube", "instagram.com".
  static String source(String url) {
    if (youTubeId(url) != null) return 'YouTube';
    final host = Uri.tryParse(url.trim())?.host ?? '';
    return host.replaceFirst(RegExp(r'^(www|m)\.'), '');
  }
}

/// A link's title and picture, as shown when the link is shared.
class LinkPreview {
  const LinkPreview({this.title, this.imageUrl});
  final String? title;
  final String? imageUrl;

  /// Reads a page's Open Graph / Twitter card tags, falling back to its
  /// `<title>`. [pageUrl] resolves relative image paths.
  static LinkPreview fromHtml(String html, Uri pageUrl) {
    final metas = <String, String>{};
    for (final m in RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      final key = _attr(tag, 'property') ?? _attr(tag, 'name');
      final content = _attr(tag, 'content');
      if (key != null && content != null && content.isNotEmpty) {
        metas.putIfAbsent(key.toLowerCase(), () => content);
      }
    }
    var title = metas['og:title'] ?? metas['twitter:title'];
    title ??= RegExp(
      r'<title[^>]*>([^<]*)</title>',
      caseSensitive: false,
    ).firstMatch(html)?.group(1);
    final image =
        metas['og:image:secure_url'] ??
        metas['og:image'] ??
        metas['twitter:image'] ??
        metas['twitter:image:src'];
    return LinkPreview(
      title: _clean(title),
      imageUrl: image == null
          ? null
          : pageUrl.resolve(_unescape(image.trim())).toString(),
    );
  }

  static String? _attr(String tag, String name) {
    final m = RegExp(
      '\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
      caseSensitive: false,
    ).firstMatch(tag);
    return m == null ? null : m.group(2) ?? m.group(3);
  }

  static String? _clean(String? s) {
    if (s == null) return null;
    final t = _unescape(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? null : t;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

/// Fetches a page's text, or null. At most [LinkPreviewer.maxBytes] are
/// read: the tags are near the top.
typedef FetchText = Future<String?> Function(Uri url);

/// Looks up links' titles and pictures.
class LinkPreviewer {
  LinkPreviewer({FetchText? fetch}) : _fetch = fetch ?? _httpGet;
  final FetchText _fetch;

  static const maxBytes = 512 * 1024;

  /// The preview of [url]. YouTube's picture needs no lookup, and its title
  /// comes from its oEmbed endpoint. Never throws: an unreachable page just
  /// has no preview.
  Future<LinkPreview> preview(String url) async {
    try {
      final id = VideoLink.youTubeId(url);
      if (id != null) {
        return LinkPreview(
          title: await _youTubeTitle(id),
          imageUrl: VideoLink.youTubeThumb(id),
        );
      }
      if (VideoLink.isDirectVideo(url)) return const LinkPreview();
      final uri = Uri.parse(url.trim());
      final html = await _fetch(uri);
      if (html == null) return const LinkPreview();
      final p = LinkPreview.fromHtml(html, uri);
      // Some sites (Instagram, for one) only give their own name.
      final site = uri.host.split('.').reversed.elementAtOrNull(1);
      final title = p.title?.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
      return title == site ? LinkPreview(imageUrl: p.imageUrl) : p;
    } on Object {
      return const LinkPreview();
    }
  }

  /// The video's title from YouTube's oEmbed endpoint, or null.
  Future<String?> _youTubeTitle(String id) async {
    try {
      final body = await _fetch(
        Uri.https('www.youtube.com', '/oembed', {
          'url': 'https://www.youtube.com/watch?v=$id',
          'format': 'json',
        }),
      );
      if (body == null) return null;
      final json = jsonDecode(body);
      return json is Map && json['title'] is String ? json['title'] : null;
    } on Object {
      return null;
    }
  }

  static Future<String?> _httpGet(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(url);
      // Sites send their preview tags to link-preview bots more readily
      // than to unknown clients.
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'facebookexternalhit/1.1')
        ..set(HttpHeaders.acceptHeader, 'text/html,application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) break;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }
}
