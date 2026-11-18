import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/inventory_providers.dart';

/// Stock movement history (local ledger: confirmed server rows once synced,
/// plus provisional rows for changes made on this device).
class MovementsScreen extends ConsumerWidget {
  const MovementsScreen({super.key, this.copyId});
  final String? copyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final list = ref.watch(movementsProvider(copyId));
    final fmt = DateFormat('d/M/yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Sejarah Pergerakan Stok')),
      body: list.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e),
        data: (rows) => rows.isEmpty
            ? const Center(child: Text('Tiada pergerakan stok direkodkan dalam peranti ini.'))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final v = rows[i];
                  final m = v.movement;
                  final q = m.quantity;
                  final scheme = Theme.of(context).colorScheme;
                  return ListTile(
                    key: Key('movement.${m.id}'),
                    leading: CircleAvatar(
                      backgroundColor: q > 0 ? Colors.green.shade100 : (q < 0 ? scheme.errorContainer : scheme.surfaceContainerHighest),
                      child: Text(q > 0 ? '+$q' : '$q'),
                    ),
                    title: Text('${movementLabels[m.movementType] ?? m.movementType} • ${v.barcode}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        v.title,
                        if (m.fromStatus != null && m.fromStatus != m.toStatus) '${m.fromStatus} → ${m.toStatus}',
                        if (v.from != v.to) '${v.from ?? '-'} → ${v.to ?? '-'}',
                        if (m.referenceNumber != null) 'Rujukan ${m.referenceNumber}',
                        if (m.remarks != null) m.remarks!,
                        fmt.format(m.createdAt) + (m.provisional ? '  •  belum disahkan' : ''),
                      ].join('\n'),
                    ),
                    isThreeLine: true,
                  );
                },
              ),
      ),
    );
  }
}
