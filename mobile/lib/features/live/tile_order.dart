import 'package:flutter/foundation.dart';

/// The order of other people's tiles across pages.
///
/// The order is kept stable, so people don't jump around: newcomers go at
/// the end. Only three things move someone: pinning (first, and shown
/// large), being the host (moved onto the first page if they'd be off it),
/// and speaking for [promoteAfter] while off the first page (moved to the
/// front, pushing the last person on the first page to the second). Nothing
/// moves while [update] is told the person is swiping.
class TileOrder {
  TileOrder({
    this.pageSize = 6,
    this.pinnedPageSize = 3,
    this.promoteAfter = const Duration(seconds: 2),
  });

  /// Tiles on a page.
  final int pageSize;

  /// Tiles on the first page when someone is pinned: them, large, and a
  /// strip of the next few.
  final int pinnedPageSize;
  final Duration promoteAfter;

  final List<String> _order = [];
  final Map<String, DateTime> _speakingSince = {};
  String? _pinned;

  List<String> get order => List.unmodifiable(_order);

  /// Updates the order and reports whether it changed. [present] is everyone
  /// else in the room, in the order they joined.
  bool update({
    required Iterable<String> present,
    required Set<String> speaking,
    required DateTime now,
    String? pinned,
    String? host,
    bool frozen = false,
  }) {
    final before = List.of(_order);
    final here = present.toList();
    _order.removeWhere((id) => !here.contains(id));
    for (final id in here) {
      if (!_order.contains(id)) _order.add(id);
    }
    _speakingSince.removeWhere((id, _) => !speaking.contains(id));
    for (final id in speaking) {
      _speakingSince.putIfAbsent(id, () => now);
    }
    _pinned = pinned != null && _order.contains(pinned) ? pinned : null;

    if (!frozen) {
      var front = 0;
      if (_pinned != null) {
        _move(_pinned!, 0);
        front = 1;
      }
      final firstPage = _pinned != null ? pinnedPageSize : pageSize;
      if (host != null &&
          host != _pinned &&
          _order.indexOf(host) >= firstPage) {
        _move(host, front);
      }
      // Longest speakers first, so the most established one ends up at the
      // front.
      final speakers =
          _speakingSince.entries
              .where((e) => now.difference(e.value) >= promoteAfter)
              .toList()
            ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in speakers) {
        if (_order.indexOf(e.key) >= firstPage) _move(e.key, front);
      }
    }
    return !listEquals(before, _order);
  }

  void _move(String id, int to) {
    _order.remove(id);
    _order.insert(to.clamp(0, _order.length), id);
  }

  /// The tiles on each page.
  List<List<String>> get pages {
    final result = <List<String>>[];
    var start = 0;
    if (_pinned != null && _order.isNotEmpty) {
      final end = pinnedPageSize.clamp(0, _order.length);
      result.add(_order.sublist(0, end));
      start = end;
    }
    for (var i = start; i < _order.length; i += pageSize) {
      result.add(_order.sublist(i, (i + pageSize).clamp(0, _order.length)));
    }
    return result;
  }

  /// The page someone is on, or -1.
  int pageOf(String id) {
    final all = pages;
    for (var i = 0; i < all.length; i++) {
      if (all[i].contains(id)) return i;
    }
    return -1;
  }
}
