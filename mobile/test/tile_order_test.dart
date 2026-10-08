import 'package:fitmeasure/features/live/tile_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 8, 12);
  List<String> people(int n) => [for (var i = 1; i <= n; i++) 'p$i'];

  test('six to a page, in join order', () {
    final o = TileOrder()..update(present: people(14), speaking: {}, now: t0);
    expect(o.pages.map((p) => p.length), [6, 6, 2]);
    expect(o.pages.first, people(6));
  });

  test('newcomers join at the end; leavers close the gap', () {
    final o = TileOrder()..update(present: people(3), speaking: {}, now: t0);
    o.update(present: ['p1', 'p3', 'p4'], speaking: {}, now: t0);
    expect(o.order, ['p1', 'p3', 'p4']);
  });

  test('someone speaking off the first page moves up after two seconds', () {
    final o = TileOrder()..update(present: people(10), speaking: {}, now: t0);
    o.update(present: people(10), speaking: {'p9'}, now: t0);
    expect(o.pageOf('p9'), 1, reason: 'not yet: they only just started');
    final changed = o.update(
      present: people(10),
      speaking: {'p9'},
      now: t0.add(const Duration(seconds: 2)),
    );
    expect(changed, isTrue);
    expect(o.order.first, 'p9');
    expect(o.pageOf('p6'), 1, reason: 'the last on page one moves to page two');
  });

  test('a speaker already on the first page stays where they are', () {
    final o = TileOrder()..update(present: people(10), speaking: {}, now: t0);
    o.update(present: people(10), speaking: {'p4'}, now: t0);
    final changed = o.update(
      present: people(10),
      speaking: {'p4'},
      now: t0.add(const Duration(seconds: 5)),
    );
    expect(changed, isFalse);
    expect(o.order, people(10));
  });

  test('a short burst of speech moves nobody', () {
    final o = TileOrder()..update(present: people(10), speaking: {}, now: t0);
    o.update(present: people(10), speaking: {'p9'}, now: t0);
    o.update(
      present: people(10),
      speaking: {},
      now: t0.add(const Duration(seconds: 1)),
    );
    o.update(
      present: people(10),
      speaking: {'p9'},
      now: t0.add(const Duration(seconds: 2)),
    );
    expect(o.pageOf('p9'), 1, reason: 'the two seconds start again');
  });

  test('nothing moves while frozen (mid-swipe), and it catches up after', () {
    final o = TileOrder()..update(present: people(10), speaking: {}, now: t0);
    o.update(present: people(10), speaking: {'p9'}, now: t0);
    final later = t0.add(const Duration(seconds: 3));
    o.update(present: people(10), speaking: {'p9'}, now: later, frozen: true);
    expect(o.pageOf('p9'), 1);
    o.update(present: people(10), speaking: {'p9'}, now: later);
    expect(o.order.first, 'p9');
  });

  test('the pinned person comes first, with two others on their page', () {
    final o = TileOrder()
      ..update(present: people(10), speaking: {}, now: t0, pinned: 'p8');
    expect(o.pages.first, ['p8', 'p1', 'p2']);
    expect(o.pages.map((p) => p.length), [3, 6, 1]);
  });

  test('the host is brought onto the first page', () {
    final o = TileOrder()
      ..update(present: people(10), speaking: {}, now: t0, host: 'p9');
    expect(o.pageOf('p9'), 0);
  });

  test('a promoted speaker goes after the pinned person', () {
    final o = TileOrder()
      ..update(present: people(10), speaking: {}, now: t0, pinned: 'p2');
    o.update(present: people(10), speaking: {'p9'}, now: t0, pinned: 'p2');
    o.update(
      present: people(10),
      speaking: {'p9'},
      now: t0.add(const Duration(seconds: 2)),
      pinned: 'p2',
    );
    expect(o.order.take(2), ['p2', 'p9']);
  });
}
