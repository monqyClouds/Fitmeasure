import 'dart:async';

import 'package:drift/drift.dart';

import '../db/database.dart';

extension LiveQuery on AppDatabase {
  /// Runs [load] now and again whenever any of [tables] changes. For results
  /// assembled from several queries, which a single drift `watch()` can't
  /// express. Changes arriving mid-load trigger one more load, not many.
  Stream<T> watchLoad<T>(
    Iterable<TableInfo> tables,
    Future<T> Function() load,
  ) {
    late final StreamController<T> controller;
    StreamSubscription<void>? updates;
    var loading = false;
    var dirty = false;

    Future<void> run() async {
      if (loading) {
        dirty = true;
        return;
      }
      loading = true;
      do {
        dirty = false;
        try {
          final value = await load();
          if (!controller.isClosed) controller.add(value);
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        }
      } while (dirty && !controller.isClosed);
      loading = false;
    }

    controller = StreamController<T>(
      onListen: () {
        updates = tableUpdates(TableUpdateQuery.onAllTables(tables))
            .listen((_) => run());
        run();
      },
      onCancel: () async {
        await updates?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }
}
