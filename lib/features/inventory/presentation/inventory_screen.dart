import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../data/local/dao/inventory_dao.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/inventory_providers.dart';

/// Inventory hub: report + actions.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final canChange = ref.watch(activePermissionsProvider).canRegisterBooks;
    final report = ref.watch(inventoryReportProvider);
    return Scaffold(
      key: ValueKey('inventory.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Inventori'),
        actions: [
          IconButton(
            tooltip: 'Muat semula',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(inventoryReportProvider),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(inventoryReportProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canChange) ...[
                  _Action(Icons.rule, 'Tukar status (pukal)', 'inventory.status', () => context.push(Routes.inventoryStatus)),
                  _Action(Icons.move_up, 'Pindah lokasi (pukal)', 'inventory.relocate',
                      () => context.push(Routes.inventoryRelocate)),
                  _Action(Icons.fact_check_outlined, 'Semakan stok', 'inventory.stocktake',
                      () => context.push(Routes.stocktake)),
                ],
                _Action(Icons.timeline, 'Sejarah pergerakan', 'inventory.movements', () => context.push(Routes.movements)),
                _Action(Icons.library_add, 'Tambah naskhah', 'inventory.addCopies', () => context.go(Routes.books)),
              ],
            ),
            const SizedBox(height: 16),
            report.when(
              loading: () => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(inventoryReportProvider)),
              data: (r) => _ReportView(report: r),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.keyName, this.onTap);
  final IconData icon;
  final String label;
  final String keyName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      ActionChip(key: Key(keyName), avatar: Icon(icon, size: 18), label: Text(label), onPressed: onTap);
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});
  final InventoryReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final n = NumberFormat.decimalPattern('ms');
    final money = NumberFormat.currency(locale: 'ms', symbol: 'RM ', decimalDigits: 2);
    final t = Theme.of(context).textTheme;
    Widget section(String title, List<Widget> rows) => Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: Text(title, style: t.titleMedium)),
              ...rows,
            ]),
          ),
        );
    // Label/value row that wraps (a ListTile trailing cannot shrink and
    // breaks layout with large accessibility fonts).
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(label)),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: Text(value, textAlign: TextAlign.end)),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r.pendingChanges > 0)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text('${n.format(r.pendingChanges)} perubahan belum disegerakkan'),
              subtitle: const Text('Laporan ini dikira daripada data dalam peranti, termasuk perubahan tersebut.'),
            ),
          ),
        section('Ringkasan', [
          row('Jumlah judul', n.format(r.titles)),
          row('Jumlah naskhah', n.format(r.copies)),
          row('Naskhah dalam stok (tersedia + dalam proses)', n.format(r.inStock)),
          row('Nilai perolehan direkod', money.format(r.totalValueCents / 100)),
        ]),
        section('Mengikut status', [
          for (final s in CopyStatus.values)
            if ((r.byStatus[s.value] ?? 0) > 0) row(s.label, n.format(r.byStatus[s.value])),
        ]),
        section('Mengikut keadaan', [
          for (final c in CopyCondition.values)
            if ((r.byCondition[c.value] ?? 0) > 0) row(c.label, n.format(r.byCondition[c.value])),
        ]),
        section('Mengikut lokasi rak', [for (final l in r.byLocation) row(l.label, n.format(l.count))]),
        section('Mengikut kategori', [
          for (final c in r.byCategory) row(c.name, '${n.format(c.titles)} judul • ${n.format(c.copies)} naskhah'),
        ]),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Dijana ${DateFormat('d/M/yyyy HH:mm').format(r.generatedAt)}', style: t.bodySmall),
        ),
      ],
    );
  }
}
