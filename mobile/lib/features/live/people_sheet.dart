import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'live_protocol.dart';
import 'room_client.dart';

/// Everyone in the room, with their role, mic and camera, and what our role
/// lets us do to each; the host's and moderators' room switches; and our own
/// visibility.
void showPeopleSheet(BuildContext context, RoomClient client) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListenableBuilder(
        listenable: client,
        builder: (context, _) => _PeopleList(client: client, scroll: scroll),
      ),
    ),
  );
}

class _PeopleList extends StatelessWidget {
  const _PeopleList({required this.client, required this.scroll});
  final RoomClient client;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final isHost = client.myRole == Role.host;
    final canLock = isHost || client.myRole == Role.moderator;
    final others = client.participants.values.toList();
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text('People (${others.length + 1})', style: t.titleLarge),
        const SizedBox(height: 12),
        if (canLock)
          _Switch(
            icon: Icons.lock_rounded,
            title: 'Lock room',
            subtitle: 'Nobody new can join',
            value: client.locked,
            onChanged: client.setLocked,
          ),
        if (isHost)
          _Switch(
            icon: Icons.groups_rounded,
            title: 'Everyone can moderate',
            subtitle: 'Anyone can mute or remove others',
            value: client.everyoneCanModerate,
            onChanged: client.setEveryoneCanModerate,
          ),
        _Switch(
          icon: Icons.visibility_off_rounded,
          title: 'Only the host sees my video',
          subtitle: 'Everyone still hears you',
          value: client.myVisibility == VideoVisibility.trainerOnly,
          onChanged: (on) => client.setVisibility(
            on ? VideoVisibility.trainerOnly : VideoVisibility.everyone,
          ),
        ),
        const SizedBox(height: 8),
        _Person(
          name: '${client.name} (you)',
          role: client.myRole,
          mic: client.micOn,
          camera: client.cameraOn,
          trainerOnly: client.myVisibility == VideoVisibility.trainerOnly,
        ),
        for (final p in others)
          _Person(
            name: p.name.isEmpty ? 'Joining…' : p.name,
            role: p.role,
            mic: p.mic,
            camera: p.camera,
            trainerOnly: p.visibility == VideoVisibility.trainerOnly,
            menu: _actions(context, p),
          ),
      ],
    );
  }

  /// What our role lets us do to p. The server checks every one again.
  Widget? _actions(BuildContext context, RemoteParticipant p) {
    final c = client;
    final items = <(String, IconData, VoidCallback)>[
      if (c.canModerate) ...[
        p.mic
            ? (
                'Mute microphone',
                Icons.mic_off_rounded,
                () => c.mute(p.id, 'mic'),
              )
            : (
                'Ask to unmute',
                Icons.mic_rounded,
                () => c.requestUnmute(p.id, 'mic'),
              ),
        p.camera
            ? (
                'Turn off camera',
                Icons.videocam_off_rounded,
                () => c.mute(p.id, 'camera'),
              )
            : (
                'Ask to turn on camera',
                Icons.videocam_rounded,
                () => c.requestUnmute(p.id, 'camera'),
              ),
      ],
      if (c.myRole == Role.host) ...[
        p.role == Role.moderator
            ? (
                'Remove as moderator',
                Icons.remove_moderator_rounded,
                () => c.setRole(p.id, Role.participant),
              )
            : (
                'Make moderator',
                Icons.add_moderator_rounded,
                () => c.setRole(p.id, Role.moderator),
              ),
        ('Make host', Icons.star_rounded, () => c.transferHost(p.id)),
      ],
      if (c.canModerate && p.role != Role.host)
        (
          'Remove from room',
          Icons.person_remove_rounded,
          () => _confirmRemove(context, p),
        ),
    ];
    if (items.isEmpty) return null;
    return PopupMenuButton<VoidCallback>(
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        for (final (label, icon, action) in items)
          PopupMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(BuildContext context, RemoteParticipant p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text('They leave the room straight away.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) client.remove(p.id);
  }
}

class _Person extends StatelessWidget {
  const _Person({
    required this.name,
    required this.role,
    required this.mic,
    required this.camera,
    required this.trainerOnly,
    this.menu,
  });

  final String name;
  final String role;
  final bool mic;
  final bool camera;
  final bool trainerOnly;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final colors = AppColors.profileColors;
    final color = colors[name.hashCode.abs() % colors.length];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ProfileAvatar(name: name, color: color, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: t.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (role != Role.participant || trainerOnly)
                  Text(
                    [
                      if (role == Role.host) 'Host',
                      if (role == Role.moderator) 'Moderator',
                      if (trainerOnly) 'Video to the host only',
                    ].join(' · '),
                    style: t.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            mic ? Icons.mic_rounded : Icons.mic_off_rounded,
            size: 20,
            color: mic ? AppColors.textSecondary : AppColors.danger,
          ),
          const SizedBox(width: 8),
          Icon(
            camera ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            size: 20,
            color: camera ? AppColors.textSecondary : AppColors.danger,
          ),
          menu ?? const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: AppColors.textSecondary),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall!
            .copyWith(color: AppColors.textTertiary),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
