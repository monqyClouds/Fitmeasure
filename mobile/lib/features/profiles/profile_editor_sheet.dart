import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../widgets/common.dart';

/// Creates a profile, or edits [profile] when given. Returns the profile id.
Future<int?> showProfileEditor(BuildContext context, {Profile? profile}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ProfileEditor(profile: profile),
  );
}

class _ProfileEditor extends ConsumerStatefulWidget {
  const _ProfileEditor({this.profile});
  final Profile? profile;

  @override
  ConsumerState<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<_ProfileEditor> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late int _color =
      widget.profile?.color ?? AppColors.profileColors.first.toARGB32();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final repo = ref.read(profileRepoProvider);
    final id = widget.profile?.id;
    if (id == null) {
      final newId = await repo.create(name: name, color: _color);
      if (mounted) Navigator.pop(context, newId);
    } else {
      await repo.update(id, name: name, color: _color);
      if (mounted) Navigator.pop(context, id);
    }
  }

  Future<void> _delete() async {
    final profile = widget.profile!;
    final ok = await confirmDialog(
      context,
      title: 'Delete ${profile.name}?',
      message:
          'All workouts, plans, measurements and media for this person '
          'will be permanently removed.',
    );
    if (!ok) return;
    if (ref.read(currentProfileIdProvider) == profile.id) {
      await ref.read(currentProfileIdProvider.notifier).select(null);
    }
    await ref.read(profileRepoProvider).delete(profile.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = Color(_color);
    final editing = widget.profile != null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ValueListenableBuilder(
                valueListenable: _name,
                builder: (context, v, _) =>
                    ProfileAvatar(name: v.text, color: color, size: 56),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  editing ? 'Edit person' : 'New person',
                  style: t.headlineSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            autofocus: !editing,
            textCapitalization: TextCapitalization.words,
            maxLength: 40,
            decoration: const InputDecoration(
              hintText: 'Name',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 24),
          Text('Colour', style: t.titleSmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in AppColors.profileColors)
                _Swatch(
                  color: c,
                  selected: c.toARGB32() == _color,
                  onTap: () => setState(() => _color = c.toARGB32()),
                ),
            ],
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: AnimatedContainer(
              duration: Motion.medium,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: onColor(color),
                ),
                onPressed: _name.text.trim().isEmpty ? null : _save,
                child: Text(editing ? 'Save' : 'Create'),
              ),
            ),
          ),
          if (editing) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _delete,
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                child: const Text('Delete this person'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.standard,
        width: 44,
        height: 44,
        padding: EdgeInsets.all(selected ? 4 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: AnimatedOpacity(
            opacity: selected ? 1 : 0,
            duration: Motion.fast,
            child: Icon(Icons.check_rounded, size: 18, color: onColor(color)),
          ),
        ),
      ),
    );
  }
}
