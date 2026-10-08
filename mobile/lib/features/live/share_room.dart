import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import 'rooms_api.dart';

/// The message a room is shared with.
String inviteText(LiveRoom room) =>
    'Train with me live on Fitmeasure: ${room.name}\n'
    '${room.link}\n'
    'Or enter room ID ${room.displayId} in the app.';

/// Shows how to invite people to [room]: its link and ID to copy, and the
/// phone's share sheet.
Future<void> shareRoom(BuildContext context, LiveRoom room) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => _InviteSheet(room: room),
    );

class _InviteSheet extends StatelessWidget {
  const _InviteSheet({required this.room});
  final LiveRoom room;

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final link = room.link.toString();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Invite to ${room.name}', style: t.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Anyone with the link or ID can join.',
              style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
            ),
            const SizedBox(height: 20),
            Center(
              child: RoomIdChip(
                room: room,
                large: true,
                onTap: () => _copy(context, room.id, 'Room ID'),
              ),
            ),
            const SizedBox(height: 16),
            Material(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(Radii.tile),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.tile),
                ),
                leading: const Icon(Icons.link_rounded),
                title: Text(
                  link.replaceFirst(RegExp('^https?://'), ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.copy_rounded, size: 20),
                onTap: () => _copy(context, link, 'Link'),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => SharePlus.instance.share(
                ShareParams(text: inviteText(room), subject: room.name),
              ),
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Share link'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A room's ID, big and spaced out so it can be read aloud or typed.
class RoomIdChip extends StatelessWidget {
  const RoomIdChip({
    super.key,
    required this.room,
    this.large = false,
    this.onTap,
  });

  final LiveRoom room;
  final bool large;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(Radii.tile),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.tile),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: large ? 22 : 16,
            vertical: large ? 12 : 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ROOM ID',
                style: t.labelSmall!.copyWith(
                  color: accent,
                  letterSpacing: 1.5,
                ),
              ),
              Text(
                room.displayId.toUpperCase(),
                style: (large ? t.headlineMedium : t.titleLarge)!.copyWith(
                  letterSpacing: large ? 6 : 4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
