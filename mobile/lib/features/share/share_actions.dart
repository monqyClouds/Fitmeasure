import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/sharing.dart';
import '../live/rooms_api.dart';
import 'shares_api.dart';

/// Shares [e] as a link, with the profile's video links for it.
Future<void> shareExercise(
  BuildContext context,
  WidgetRef ref,
  Exercise e,
) async {
  final profileId = ref.read(currentProfileIdProvider)!;
  final sharing = ref.read(sharingProvider);
  final share = await sharing.exercise(e, profileId);
  final ownFiles = await sharing.hasOwnFiles(e.id, profileId);
  if (!context.mounted) return;
  final videos = share.exercise!.videos.length;
  await _share(
    context,
    share,
    videos == 0
        ? '${e.name} on Fitmeasure'
        : '${e.name}: how to do it, with $videos '
              '${videos == 1 ? 'video' : 'videos'}',
    note: ownFiles
        ? 'Your own photos and videos stay on this phone; only links are '
              'shared.'
        : null,
  );
}

/// Shares [plan]: its days, targets and exercises, with their video links.
Future<void> sharePlan(BuildContext context, WidgetRef ref, Plan plan) async {
  final days = await ref.read(planRepoProvider).watchDays(plan.id).first;
  final share = await ref.read(sharingProvider).plan(plan, days);
  if (!context.mounted) return;
  if (days.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add a day to the plan before sharing it')),
    );
    return;
  }
  await _share(
    context,
    share,
    '${plan.name}: a ${days.length}-day plan on Fitmeasure',
  );
}

Future<void> _share(
  BuildContext context,
  ShareContent share,
  String text, {
  String? note,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  // The link is made on the server; show that something's happening.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  Uri link;
  try {
    link = await const SharesApi().create(share);
  } on RoomsApiException catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  navigator.pop();
  await SharePlus.instance.share(
    ShareParams(text: '$text\n$link', subject: share.title),
  );
  if (note != null) messenger.showSnackBar(SnackBar(content: Text(note)));
}
