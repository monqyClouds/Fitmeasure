import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import '../cycles/cycles_screen.dart';
import 'profile_editor_sheet.dart';

Future<void> showProfileMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _ProfileMenu(),
  );
}

class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final others = (ref.watch(profilesProvider).value ?? const [])
        .where((p) => p.id != profile?.id)
        .toList();
    final t = Theme.of(context).textTheme;
    if (profile == null) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Row(
                children: [
                  ProfileAvatar(
                    name: profile.name,
                    color: Color(profile.color),
                    size: 52,
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Text(profile.name, style: t.headlineSmall)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit profile'),
              onTap: () {
                Navigator.pop(context);
                showProfileEditor(context, profile: profile);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timeline_rounded),
              title: const Text('Cycles'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CyclesScreen()),
                );
              },
            ),
            if (others.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Divider(),
              ),
              for (final o in others)
                ListTile(
                  leading: ProfileAvatar(
                    name: o.name,
                    color: Color(o.color),
                    size: 32,
                  ),
                  title: Text('Switch to ${o.name}'),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(currentProfileIdProvider.notifier).select(o.id);
                  },
                ),
            ],
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('All profiles'),
              textColor: AppColors.textSecondary,
              onTap: () {
                Navigator.pop(context);
                ref.read(currentProfileIdProvider.notifier).select(null);
              },
            ),
          ],
        ),
      ),
    );
  }
}
