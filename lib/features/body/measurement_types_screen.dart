import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart';
import '../../data/repos/measurement_repo.dart';
import '../../widgets/common.dart';
import 'measurement_style.dart';

/// Add, rename, reorder and remove the measurements a profile tracks.
class MeasurementTypesScreen extends ConsumerStatefulWidget {
  const MeasurementTypesScreen({super.key});

  @override
  ConsumerState<MeasurementTypesScreen> createState() =>
      _MeasurementTypesScreenState();
}

class _MeasurementTypesScreenState
    extends ConsumerState<MeasurementTypesScreen> {
  List<int>? _order;

  Future<void> _edit([MeasurementType? type]) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _TypeDialog(type: type),
    );
    final profileId = ref.read(currentProfileIdProvider);
    if (result == null || profileId == null) return;
    final (name, unit) = result;
    final repo = ref.read(measurementRepoProvider);
    if (type == null) {
      await repo.addType(profileId, name: name, unit: unit);
    } else {
      await repo.updateType(type.id, name: name, unit: unit);
    }
  }

  Future<void> _delete(MeasurementSeries s) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete ${s.type.name}?',
      message: s.entries.isEmpty
          ? 'It will no longer be offered when logging.'
          : 'Its ${s.entries.length} entries are deleted too.',
    );
    if (ok) await ref.read(measurementRepoProvider).deleteType(s.type.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    var series = ref.watch(measurementsProvider).value ?? const [];
    final order = _order;
    if (order != null) {
      final byId = {for (final s in series) s.type.id: s};
      if (order.length == series.length && order.every(byId.containsKey)) {
        series = [for (final id in order) byId[id]!];
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Measurements')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add measurement'),
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        buildDefaultDragHandles: false,
        header: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Hold and drag to reorder. The first one is shown largest on '
            'Progress.',
            style: t.bodySmall!.copyWith(color: AppColors.textTertiary),
          ),
        ),
        itemCount: series.length,
        onReorderItem: (from, to) {
          final ids = [for (final s in series) s.type.id];
          final id = ids.removeAt(from);
          ids.insert(to, id);
          setState(() => _order = ids);
          ref.read(measurementRepoProvider).reorderTypes(ids);
        },
        proxyDecorator: (child, _, _) => Material(
          color: Colors.transparent,
          elevation: 8,
          shadowColor: Colors.black,
          borderRadius: BorderRadius.circular(Radii.tile),
          child: child,
        ),
        itemBuilder: (context, i) {
          final s = series[i];
          final style = measurementStyle(s.type);
          return Padding(
            key: ValueKey(s.type.id),
            padding: const EdgeInsets.only(bottom: 8),
            child: ReorderableDelayedDragStartListener(
              index: i,
              child: Material(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(Radii.tile),
                child: ListTile(
                  contentPadding: const EdgeInsets.only(left: 14, right: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.tile),
                  ),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: style.color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(style.icon, color: style.color, size: 20),
                  ),
                  title: Text(s.type.name, style: t.titleSmall),
                  subtitle: Text(
                    '${s.type.unit.isEmpty ? 'No unit' : s.type.unit} · '
                    '${s.entries.length} entries',
                    style: t.bodySmall!.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  onTap: () => _edit(s.type),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => _delete(s),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TypeDialog extends StatefulWidget {
  const _TypeDialog({this.type});
  final MeasurementType? type;

  @override
  State<_TypeDialog> createState() => _TypeDialogState();
}

class _TypeDialogState extends State<_TypeDialog> {
  late final _name = TextEditingController(text: widget.type?.name ?? '');
  late String _unit = widget.type?.unit ?? 'cm';

  static const _units = ['cm', 'kg', '%', 'mm', 'bpm', ''];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final units = {..._units, _unit}.toList();
    return AlertDialog(
      title: Text(widget.type == null ? 'New measurement' : 'Edit measurement'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.type == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Forearm, Resting heart rate',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final u in units)
                ChoiceChip(
                  label: Text(u.isEmpty ? 'No unit' : u),
                  selected: _unit == u,
                  onSelected: (_) => setState(() => _unit = u),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (_name.text.trim(), _unit)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
