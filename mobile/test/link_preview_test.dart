import 'package:fitmeasure/data/link_preview.dart';
import 'package:fitmeasure/features/library/video_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('video links', () {
    test('YouTube IDs come out of every kind of YouTube link', () {
      const id = 'dQw4w9WgXcQ';
      for (final url in [
        'https://www.youtube.com/watch?v=$id',
        'https://youtube.com/watch?v=$id&t=42s',
        'https://m.youtube.com/watch?v=$id',
        'https://youtu.be/$id',
        'https://youtu.be/$id?si=abc123',
        'https://www.youtube.com/shorts/$id',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube-nocookie.com/embed/$id',
        'https://www.youtube.com/live/$id',
        '  https://youtu.be/$id  ',
      ]) {
        expect(VideoLink.youTubeId(url), id, reason: url);
      }
      for (final url in [
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/watch?v=short',
        'https://notyoutube.com/watch?v=$id',
        'https://www.instagram.com/reel/abc/',
        'not a link',
      ]) {
        expect(VideoLink.youTubeId(url), isNull, reason: url);
      }
    });

    test('what plays in the app, and where links are from', () {
      expect(
        VideoLink.isDirectVideo('https://cdn.x.com/a/squat.MP4?x=1'),
        isTrue,
      );
      expect(VideoLink.playsInApp('https://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(
        VideoLink.playsInApp('https://www.instagram.com/reel/abc/'),
        isFalse,
      );
      expect(VideoLink.source('https://youtu.be/dQw4w9WgXcQ'), 'YouTube');
      expect(
        VideoLink.source('https://www.instagram.com/reel/abc/'),
        'instagram.com',
      );
      expect(VideoLink.source('https://m.tiktok.com/@a/video/1'), 'tiktok.com');
    });

    test('a link is found inside a shared message', () {
      expect(
        extractUrl('Watch this: https://youtu.be/dQw4w9WgXcQ?si=x great form'),
        'https://youtu.be/dQw4w9WgXcQ?si=x',
      );
      expect(extractUrl('no link here'), isNull);
    });
  });

  group('previews', () {
    final page = Uri.parse('https://example.com/videos/squat');

    test('Open Graph tags give the title and picture', () {
      final p = LinkPreview.fromHtml('''
        <html><head>
        <title>Ignored</title>
        <meta content="https://img.example.com/s.jpg" property="og:image">
        <meta property='og:title' content='Squat &amp; brace &quot;right&quot;'>
        </head></html>''', page);
      expect(p.title, 'Squat & brace "right"');
      expect(p.imageUrl, 'https://img.example.com/s.jpg');
    });

    test(
      'falls back to Twitter tags and <title>, resolving relative pictures',
      () {
        final p = LinkPreview.fromHtml('''
        <TITLE>
          How to   squat
        </TITLE>
        <meta name="twitter:image" content="/thumbs/s.jpg">''', page);
        expect(p.title, 'How to squat');
        expect(p.imageUrl, 'https://example.com/thumbs/s.jpg');
      },
    );

    test('a page without tags has no preview', () {
      final p = LinkPreview.fromHtml('<p>hello</p>', page);
      expect(p.title, isNull);
      expect(p.imageUrl, isNull);
    });

    test('YouTube: picture from the ID, title from oEmbed', () async {
      Uri? asked;
      final previewer = LinkPreviewer(
        fetch: (url) async {
          asked = url;
          return '{"title": "Perfect squat", "author_name": "Coach"}';
        },
      );
      final p = await previewer.preview('https://youtu.be/dQw4w9WgXcQ');
      expect(p.title, 'Perfect squat');
      expect(p.imageUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
      expect(asked!.path, '/oembed');
      expect(
        asked!.queryParameters['url'],
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
    });

    test('a title that is only the site name is dropped', () async {
      final previewer = LinkPreviewer(
        fetch: (_) async =>
            '<meta property="og:title" content="Instagram">'
            '<meta property="og:image" content="https://cdn.ig/x.jpg">',
      );
      final p = await previewer.preview('https://www.instagram.com/reel/abc/');
      expect(p.title, isNull);
      expect(p.imageUrl, 'https://cdn.ig/x.jpg');
    });

    test('a failed lookup just means no preview', () async {
      final previewer = LinkPreviewer(
        fetch: (_) async => throw Exception('offline'),
      );
      final p = await previewer.preview('https://example.com/a');
      expect(p.title, isNull);
      expect(p.imageUrl, isNull);
      // YouTube still has its picture.
      final yt = await previewer.preview('https://youtu.be/dQw4w9WgXcQ');
      expect(yt.imageUrl, isNotNull);
    });
  });
}
