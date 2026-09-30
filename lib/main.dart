import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/db/database.dart';
import 'data/repos/profile_repo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final db = AppDatabase();
  final documents = await getApplicationDocumentsDirectory();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      documentsPathProvider.overrideWithValue(documents.path),
    ],
  );

  // Reopen the last profile used, so a single user skips the picker.
  final repo = ProfileRepo(db);
  final lastId = await repo.lastUsedId();
  if (lastId != null) {
    final exists = await repo.watch(lastId).first != null;
    if (exists) {
      await container.read(currentProfileIdProvider.notifier).select(lastId);
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const FitmeasureApp(),
    ),
  );
}
