import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'prejoin_screen.dart';
import 'rooms_api.dart';
import 'saved_rooms.dart';

/// Looks up the room with [id] (the server has its name), remembers it and
/// opens its pre-join screen. Says so if there's no such room.
Future<void> openRoomById(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final LiveRoom? found;
  try {
    found = await ref.read(roomsApiProvider).find(id);
  } on RoomsApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (found == null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'No room with the ID ${id.toUpperCase()}. Check it with whoever '
          'shared it.',
        ),
      ),
    );
    return;
  }
  final room = await ref.read(savedRoomsProvider).remember(found);
  if (!navigator.mounted) return;
  openPreJoin(navigator, ref, room);
}

/// Opens the pre-join screen for [room], with our profile's name.
void openPreJoin(
  NavigatorState navigator,
  WidgetRef ref,
  LiveRoom room, {
  bool justCreated = false,
}) {
  final profile = ref.read(currentProfileProvider).value;
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => PreJoinScreen(
        room: room,
        name: profile?.name ?? '',
        justCreated: justCreated,
      ),
    ),
  );
}

/// Asks for a name, creates the room on the server, keeps its host key and
/// opens it.
Future<void> createRoomFlow(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  final room = await showModalBottomSheet<LiveRoom>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _CreateRoomSheet(),
  );
  if (room == null || !navigator.mounted) return;
  final saved = await ref.read(savedRoomsProvider).remember(room);
  if (!navigator.mounted) return;
  openPreJoin(navigator, ref, saved, justCreated: true);
}

class _CreateRoomSheet extends ConsumerStatefulWidget {
  const _CreateRoomSheet();

  @override
  ConsumerState<_CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends ConsumerState<_CreateRoomSheet> {
  final _name = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final room = await ref.read(roomsApiProvider).create(name);
      if (mounted) Navigator.pop(context, room);
    } on RoomsApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Create a room', style: t.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'You host it. It gets its own link and ID to share, and stays '
            'yours while it\'s in use.',
            style: t.bodySmall!.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _create(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Room name',
              hintText: 'Tuesday HIIT',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _name.text.trim().isEmpty || _busy ? null : _create,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('Create room'),
          ),
        ],
      ),
    );
  }
}
