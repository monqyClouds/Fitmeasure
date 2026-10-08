import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/beeper.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/backup/backup_service.dart';
import '../../data/repos/settings_repo.dart';
import '../../domain/enums.dart';
import '../../widgets/common.dart';
import '../../widgets/motion.dart';
import '../../widgets/visuals.dart';

final _dataStatsProvider = FutureProvider.autoDispose<DataStats>(
  (ref) => ref.watch(backupServiceProvider).stats(),
);

final _restorePointProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(backupServiceProvider).hasRestorePoint(),
);

final _versionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Backup and restore, workout options and app info.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  var _includeMedia = true;

  /// Large backups can't be handed to "Save" in one piece, so sharing is
  /// offered instead above this size.
  static const _saveLimit = 150 * 1024 * 1024;

  /// Runs [task] behind a blocking progress dialog.
  Future<T?> _busy<T>(String message, Future<T> Function() task) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      navigator.pop();
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<File?> _export() async {
    try {
      return await _busy(
        'Preparing your backup…',
        () =>
            ref.read(backupServiceProvider).export(includeMedia: _includeMedia),
      );
    } on Exception catch (e) {
      _snack('Couldn\'t make the backup: $e');
      return null;
    }
  }

  Future<void> _share() async {
    // iPads show the share sheet as a popover, which needs an anchor.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final file = await _export();
    if (file == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: 'Fitmeasure backup',
        title: 'Save your Fitmeasure backup',
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _save() async {
    final file = await _export();
    if (file == null) return;
    if (await file.length() > _saveLimit) {
      _snack(
        'This backup is too big to save directly. Use Share instead, or '
        'leave out photos and videos.',
      );
      return;
    }
    final saved = await FilePicker.saveFile(
      fileName: p.basename(file.path),
      bytes: await file.readAsBytes(),
      mimeType: 'application/zip',
      dialogTitle: 'Save backup',
    );
    if (saved != null) {
      HapticFeedback.mediumImpact();
      _snack('Backup saved');
    }
  }

  Future<String?> _pickBackup() async {
    final picked = await FilePicker.pickFile(dialogTitle: 'Choose a backup');
    if (picked == null) return null;
    if (picked.path case final path?) return path;
    // Not a local file: copy it somewhere readable first.
    final copy = File(
      p.join((await getTemporaryDirectory()).path, 'picked-backup.zip'),
    );
    final sink = copy.openWrite();
    await sink.addStream(picked.readAsByteStream());
    await sink.close();
    return copy.path;
  }

  Future<void> _afterRestore(String message) async {
    // Profiles may have changed completely; start again from the picker.
    await ref.read(currentProfileIdProvider.notifier).select(null);
    ref.invalidate(_restorePointProvider);
    ref.invalidate(_dataStatsProvider);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restore() async {
    final backup = ref.read(backupServiceProvider);
    final path = await _pickBackup();
    if (path == null || !mounted) return;

    final BackupInfo info;
    try {
      info = await backup.inspect(path);
    } on BackupException catch (e) {
      _snack(e.message);
      return;
    }
    if (!mounted) return;
    final ok = await confirmDialog(
      context,
      title: 'Restore this backup?',
      message:
          'From ${DateFormat('d MMM yyyy, HH:mm').format(info.createdAt)}: '
          '${info.profiles.join(', ')} · ${info.workouts} workouts · '
          '${info.measurements} measurements · ${info.mediaFiles} photos '
          'and videos.\n\nEverything on this phone is replaced. A restore '
          'point is kept so you can undo it.',
      confirmLabel: 'Restore',
    );
    if (!ok) return;
    try {
      await _busy('Restoring…', () => backup.restore(path));
    } on BackupException catch (e) {
      _snack(e.message);
      return;
    }
    await _afterRestore('Backup restored');
  }

  Future<void> _undoRestore() async {
    final ok = await confirmDialog(
      context,
      title: 'Undo the last restore?',
      message:
          'Your data goes back to how it was just before the last restore. '
          'Anything logged since then is replaced.',
      confirmLabel: 'Undo restore',
    );
    if (!ok) return;
    try {
      await _busy(
        'Restoring…',
        () => ref.read(backupServiceProvider).restoreRestorePoint(),
      );
    } on BackupException catch (e) {
      _snack(e.message);
      return;
    }
    await _afterRestore('Restore undone');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final stats = ref.watch(_dataStatsProvider).value;
    final hasPoint = ref.watch(_restorePointProvider).value ?? false;
    final keepAwake = ref.watch(keepAwakeProvider).value ?? true;
    final version = ref.watch(_versionProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: GlowBackdrop(
        color: accent,
        secondary: CycleType.endurance.color,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          children: [
            FadeSlideIn(
              child: SurfaceCard(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                      accent.withValues(alpha: 0.18),
                      AppColors.surface,
                    ),
                    AppColors.surface,
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.cloud_upload_outlined,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Back up', style: t.titleLarge),
                              Text(
                                'Everything in one file you can keep '
                                'anywhere',
                                style: t.bodySmall!.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (stats != null)
                      Row(
                        children: [
                          _Count(
                            icon: Icons.group_outlined,
                            value: stats.profiles,
                            label: 'people',
                          ),
                          _Count(
                            icon: Icons.fitness_center_rounded,
                            value: stats.workouts,
                            label: 'workouts',
                          ),
                          _Count(
                            icon: Icons.straighten_rounded,
                            value: stats.measurements,
                            label: 'measures',
                          ),
                          _Count(
                            icon: Icons.perm_media_outlined,
                            value: stats.mediaFiles,
                            label: 'media',
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _includeMedia,
                      onChanged: (v) => setState(() => _includeMedia = v),
                      title: Text(
                        'Include photos and videos',
                        style: t.titleSmall,
                      ),
                      subtitle: Text(
                        stats == null || stats.mediaFiles == 0
                            ? 'None added yet'
                            : '${stats.mediaFiles} files · '
                                  '${formatBytes(stats.mediaBytes)}',
                        style: t.bodySmall!.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _share,
                            icon: const Icon(Icons.ios_share_rounded),
                            label: const Text('Share'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _save,
                            icon: const Icon(Icons.save_alt_rounded),
                            label: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Share to Google Drive, email or a chat to keep a '
                      'copy off this phone.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              child: _ActionTile(
                icon: Icons.settings_backup_restore_rounded,
                color: CycleType.endurance.color,
                title: 'Restore from a backup',
                subtitle: 'Replaces the data on this phone',
                onTap: _restore,
              ),
            ),
            if (hasPoint) ...[
              const SizedBox(height: 10),
              _ActionTile(
                icon: Icons.undo_rounded,
                color: CycleType.bulk.color,
                title: 'Undo last restore',
                subtitle: 'Go back to the data from just before it',
                onTap: _undoRestore,
              ),
            ],
            const SizedBox(height: 26),
            const SectionHeader('Workouts'),
            Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.tile),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    value: keepAwake,
                    onChanged: (v) => ref
                        .read(settingsRepoProvider)
                        .setBool(SettingsRepo.keepAwake, v),
                    secondary: const Icon(Icons.light_mode_outlined),
                    title: Text('Keep screen on', style: t.titleSmall),
                    subtitle: Text(
                      'While a workout is open, so the rest timer stays in '
                      'view',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    value: ref.watch(timerSoundsProvider).value ?? true,
                    onChanged: (v) => ref
                        .read(settingsRepoProvider)
                        .setBool(SettingsRepo.timerSounds, v),
                    secondary: const Icon(Icons.volume_up_outlined),
                    title: Text('Timer sounds', style: t.titleSmall),
                    subtitle: Text(
                      'Beeps for the last seconds of sets, rest and breaks, '
                      'over your music',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const SectionHeader('About'),
            Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.tile),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.lock_outline_rounded),
                    title: Text('Your data stays here', style: t.titleSmall),
                    subtitle: Text(
                      'Nothing is uploaded unless you share an exercise or '
                      'plan, or join a live session. Back up to keep a copy '
                      'elsewhere.',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const Divider(indent: 20, endIndent: 20),
                  ListTile(
                    leading: Image.asset(
                      'assets/icon/icon-512.png',
                      width: 32,
                      height: 32,
                    ),
                    title: Text('Fitmeasure', style: t.titleSmall),
                    subtitle: Text(
                      version == null ? '' : 'Version $version',
                      style: t.bodySmall!.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'Fitmeasure',
                      applicationVersion: version,
                      applicationIcon: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.asset(
                          'assets/icon/icon-512.png',
                          width: 72,
                          height: 72,
                        ),
                      ),
                    ),
                    trailing: Text(
                      'Licences',
                      style: t.labelMedium!.copyWith(color: accent),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.value, required this.label});
  final IconData icon;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: AppColors.textTertiary),
          const SizedBox(height: 4),
          Text(
            NumberFormat.decimalPattern().format(value),
            style: t.titleMedium,
          ),
          Text(
            label,
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Pressable(
      borderRadius: Radii.tile,
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.tile),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall),
                  Text(
                    subtitle,
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
