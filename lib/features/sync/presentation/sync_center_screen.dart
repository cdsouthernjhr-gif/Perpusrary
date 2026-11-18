import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/local/database/app_database.dart';
import '../../../data/providers.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../books/application/catalog_providers.dart';
import '../../libraries/application/library_context.dart';
import '../application/sync_controller.dart';
import '../application/sync_status.dart';

final _problemsProvider = StreamProvider.autoDispose<List<SyncQueueEntry>>((ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) return const Stream.empty();
  return ref.watch(syncQueueDaoProvider).watchProblems(lib.id);
});

const _errorLabels = {
  'duplicate_barcode': 'Barcode sudah digunakan oleh naskhah lain di pelayan.',
  'duplicate_accession_number': 'Nombor perolehan sudah digunakan.',
  'duplicate_category': 'Kategori dengan nama ini sudah wujud.',
  'duplicate_location': 'Lokasi rak ini sudah wujud.',
  'version_mismatch': 'Rekod telah diubah oleh pengguna lain.',
  'already_exists': 'Rekod sudah wujud di pelayan.',
  'forbidden': 'Peranan anda tidak membenarkan perubahan ini.',
  'not_found': 'Rekod tidak dijumpai di pelayan.',
  'deleted_on_server': 'Rekod telah dipadam di pelayan.',
  'invalid_reference': 'Rekod berkaitan (buku/kategori/lokasi) tidak sah atau belum diterima.',
  'validation_failed': 'Data tidak memenuhi peraturan pelayan.',
  'malformed_operation': 'Operasi rosak.',
  'network': 'Tiada sambungan – akan dicuba semula.',
};

const _fieldLabels = {
  'title': 'Tajuk',
  'subtitle': 'Subjudul',
  'isbn': 'ISBN',
  'author': 'Pengarang',
  'publisher': 'Penerbit',
  'publication_year': 'Tahun',
  'edition': 'Edisi',
  'language': 'Bahasa',
  'description': 'Keterangan',
  'category_id': 'Kategori',
  'call_number': 'No. panggilan',
  'barcode': 'Barcode',
  'accession_number': 'No. perolehan',
  'condition': 'Keadaan',
  'status': 'Status',
  'location_id': 'Lokasi',
  'acquisition_date': 'Tarikh perolehan',
  'acquisition_source': 'Sumber',
  'acquisition_cost': 'Kos',
  'remarks': 'Catatan',
  'name': 'Nama',
  'code': 'Kod',
  'rack_code': 'Kod rak',
  'shelf_code': 'Kod para',
  'building': 'Bangunan',
  'room': 'Bilik',
  'section': 'Seksyen',
};

class SyncCenterScreen extends ConsumerWidget {
  const SyncCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final ui = ref.watch(syncControllerProvider);
    final running = ref.watch(syncActivityProvider);
    final online = ref.watch(isOnlineProvider);
    final counts = ref.watch(syncCountsProvider(lib.id)).value;
    final problems = ref.watch(_problemsProvider).value ?? const <SyncQueueEntry>[];
    final fmt = DateFormat('d/M/yyyy HH:mm');
    final r = ui.lastReport;

    return Scaffold(
      key: ValueKey('sync.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Sync Center')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(lib.name, style: Theme.of(context).textTheme.titleMedium)),
                    SyncIndicatorChip(libraryId: lib.id),
                  ]),
                  const SizedBox(height: 8),
                  Text('Sync berjaya terakhir: ${ui.lastSyncAt == null ? '-' : fmt.format(ui.lastSyncAt!)}'),
                  if (counts != null)
                    Text('Menunggu: ${counts.pending} • Gagal: ${counts.failed} • '
                        'Ditolak: ${counts.rejected} • Konflik: ${counts.conflicts}',
                        key: const Key('sync.counts')),
                  if (r != null)
                    Text('Terakhir: ${r.applied} diterima, ${r.conflicts} konflik, ${r.rejected} ditolak, '
                        '${r.pulled} rekod diterima dari pelayan'),
                  if (ui.message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(ui.message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('sync.now'),
                    onPressed: running || !online ? null : () => ref.read(syncControllerProvider.notifier).syncNow(),
                    icon: running
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync),
                    label: Text(online ? (running ? 'Sedang sync…' : 'Sync sekarang') : 'Luar talian'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Perlu tindakan (${problems.length})', style: Theme.of(context).textTheme.titleMedium),
          if (problems.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Tiada masalah sync.')),
          for (final op in problems) _ProblemCard(op: op),
        ],
      ),
    );
  }
}

class _ProblemCard extends ConsumerWidget {
  const _ProblemCard({required this.op});
  final SyncQueueEntry op;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider)!;
    final perms = ref.watch(activePermissionsProvider);
    final engine = ref.read(syncEngineProvider);
    final canOverride = op.entityType == 'book_copies' ? perms.canRegisterBooks : perms.canEditCatalog;
    final fmt = DateFormat('d/M HH:mm');

    Future<void> resolve(Future<void> Function() action, String done) async {
      final ok = await runWithFeedback(context, action, success: done);
      if (ok) await ref.read(syncControllerProvider.notifier).syncNow();
    }

    final title = switch (op.state) {
      'conflict' => 'Konflik data',
      'rejected' => 'Ditolak oleh pelayan',
      _ => 'Gagal – cubaan ${op.attempts}',
    };
    return Card(
      key: Key('problem.${op.operationId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            FutureBuilder<String>(
              future: ref.read(syncQueueDaoProvider).describe(lib.id, op.entityType, op.entityId),
              builder: (_, s) => Text(s.data ?? '…'),
            ),
            Text(_errorLabels[op.lastErrorCode] ?? (op.lastErrorMessage ?? op.lastErrorCode ?? '')),
            if (op.state == 'failed' && op.nextAttemptAt != null)
              Text('Cubaan seterusnya: ${fmt.format(op.nextAttemptAt!)}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (op.state == 'conflict') ...[
                  OutlinedButton(
                    onPressed: () => _showDiff(context, op),
                    child: const Text('Lihat perbezaan'),
                  ),
                  OutlinedButton(
                    key: Key('problem.keepServer.${op.operationId}'),
                    onPressed: () => resolve(() => engine.keepServerVersion(op.operationId), 'Versi pelayan digunakan.'),
                    child: const Text('Guna versi pelayan'),
                  ),
                  if (canOverride)
                    FilledButton(
                      key: Key('problem.keepMine.${op.operationId}'),
                      onPressed: () => resolve(() => engine.keepMyVersion(op.operationId), 'Perubahan anda dihantar semula.'),
                      child: const Text('Kekalkan perubahan saya'),
                    ),
                ],
                if (op.state == 'rejected') ...[
                  if (op.lastErrorCode == 'duplicate_barcode' && op.entityType == 'book_copies' && perms.canRegisterBooks)
                    FilledButton(
                      key: Key('problem.newBarcode.${op.operationId}'),
                      onPressed: () => resolve(() async {
                        final code = await ref.read(catalogActionsProvider).generateBarcode();
                        await engine.replaceBarcode(op.operationId, code);
                      }, 'Barcode baharu dijana dan akan dihantar.'),
                      child: const Text('Jana barcode baharu'),
                    ),
                  OutlinedButton(
                    key: Key('problem.discard.${op.operationId}'),
                    onPressed: () => resolve(() => engine.keepServerVersion(op.operationId), 'Perubahan dibuang.'),
                    child: const Text('Buang perubahan saya'),
                  ),
                ],
                if (op.state == 'failed')
                  OutlinedButton(
                    key: Key('problem.retry.${op.operationId}'),
                    onPressed: () => resolve(() => engine.retryNow(op.operationId), 'Mencuba semula…'),
                    child: const Text('Cuba sekarang'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDiff(BuildContext context, SyncQueueEntry op) async {
    final mine = jsonDecode(op.payload) as Map<String, dynamic>;
    final server = ((op.serverResult == null ? null : jsonDecode(op.serverResult!)) as Map<String, dynamic>?)?['server_row']
        as Map<String, dynamic>?;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Perbezaan'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Medan yang anda ubah, berbanding nilai semasa di pelayan:'),
              const SizedBox(height: 8),
              for (final e in mine.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${_fieldLabels[e.key] ?? e.key}\n  Anda: ${e.value ?? '-'}\n  Pelayan: ${server?[e.key] ?? '-'}',
                  ),
                ),
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Tutup'))],
      ),
    );
  }
}
