import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:printing/printing.dart';

import '../../../app/router/routes.dart';
import '../../../data/local/database/app_database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/library_repositories.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../barcode/application/label_pdf.dart';
import '../../libraries/application/library_context.dart';
import '../application/catalog_providers.dart';
import 'catalog_widgets.dart';

class BookDetailScreen extends ConsumerWidget {
  const BookDetailScreen({super.key, required this.bookId});
  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(bookProvider(bookId));
    final copies = ref.watch(copiesProvider(bookId));
    final perms = ref.watch(activePermissionsProvider);

    return book.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorView(error: e)),
      data: (b) {
        if (b == null || b.deletedAt != null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('Buku tidak dijumpai atau telah dipadam.')));
        }
        final copyList = copies.value ?? const <CopyListItem>[];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Butiran Buku'),
            actions: [
              IconButton(
                tooltip: 'Sejarah perubahan',
                icon: const Icon(Icons.history),
                onPressed: () => _showHistory(context, ref, b.id, 'buku'),
              ),
              if (copyList.isNotEmpty)
                IconButton(
                  tooltip: 'Cetak label barcode',
                  icon: const Icon(Icons.print_outlined),
                  onPressed: () => _printLabels(context, ref, b, copyList),
                ),
              if (perms.canEditCatalog)
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await context.push(Routes.bookEdit(b.id));
                      return;
                    }
                    if (v == 'delete') {
                      final sure = await _confirm(context, 'Padam buku ini?',
                          'Rekod akan ditanda dipadam (soft delete) dan disegerakkan ke pelayan.');
                      if (sure && context.mounted) {
                        final ok = await runWithFeedback(context, () => ref.read(catalogActionsProvider).deleteBook(b.id),
                            success: 'Buku dipadam.');
                        if (ok && context.mounted) context.pop();
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit maklumat')),
                    PopupMenuItem(value: 'delete', child: Text('Padam buku')),
                  ],
                ),
            ],
          ),
          floatingActionButton: perms.canRegisterBooks
              ? FloatingActionButton.extended(
                  key: const Key('book.addCopy'),
                  onPressed: () => context.push(Routes.copyNew(b.id)),
                  icon: const Icon(Icons.add),
                  label: const Text('Tambah naskhah'),
                )
              : null,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BookCover(url: b.coverImagePath, size: 80),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.title, key: const Key('bookDetail.title'), style: Theme.of(context).textTheme.titleLarge),
                        if (b.subtitle != null) Text(b.subtitle!),
                        if (b.author != null) Text(b.author!, style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 8),
                        Row(children: [
                          SyncStateIcon(state: b.syncState),
                          const SizedBox(width: 6),
                          Flexible(child: Text(_syncText(b.syncState))),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _info('ISBN', b.isbn),
              _info('Penerbit', b.publisher),
              _info('Tahun', b.publicationYear?.toString()),
              _info('Edisi', b.edition),
              _info('Bahasa', b.language),
              _info('No. panggilan', b.callNumber),
              _info('Sumber maklumat', const {
                'google_books': 'Google Books',
                'open_library': 'Open Library',
                'library_of_congress': 'Library of Congress',
                'import': 'Import Excel',
              }[b.metadataSource] ?? 'Manual'),
              if (b.description != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(b.description!)),
              const Divider(height: 32),
              Text('Naskhah (${copyList.length})', style: Theme.of(context).textTheme.titleMedium),
              if (copyList.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada naskhah fizikal.')),
              for (final c in copyList)
                ListTile(
                  key: Key('copy.${c.copy.barcode}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code_2),
                  title: Text(c.copy.barcode),
                  subtitle: Text([
                    if (c.copy.accessionNumber != null) 'No. perolehan ${c.copy.accessionNumber}',
                    CopyCondition.parse(c.copy.condition).label,
                    c.location == null ? 'Lokasi belum ditetapkan' : locationLabel(c.location!),
                  ].join(' • ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [CopyStatusChip(status: c.copy.status), SyncStateIcon(state: c.copy.syncState)],
                  ),
                  onTap: perms.canRegisterBooks ? () => context.push(Routes.copyEdit(b.id, c.copy.id)) : null,
                  onLongPress: () => _showHistory(context, ref, c.copy.id, 'naskhah'),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _syncText(String s) => switch (s) {
        'pending' => 'Menunggu sync ke pelayan',
        'conflict' => 'Konflik data – semak di Sync Center',
        'rejected' => 'Ditolak oleh pelayan',
        _ => 'Disegerakkan',
      };

  Widget _info(String label, String? value) => value == null || value.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [SizedBox(width: 130, child: Text(label)), Expanded(child: Text(value))],
          ),
        );

  Future<void> _printLabels(BuildContext context, WidgetRef ref, LocalBook b, List<CopyListItem> copies) async {
    final lib = ref.read(activeLibraryProvider)!;
    await runWithFeedback(context, () async {
      final labels = [
        for (final c in copies)
          LabelData(
            barcode: c.copy.barcode,
            title: b.title,
            accessionNumber: c.copy.accessionNumber,
            callNumber: b.callNumber,
          ),
      ];
      await Printing.layoutPdf(
        name: 'Label ${b.title}',
        onLayout: (_) => buildLabelsPdf(libraryName: lib.name, labels: labels),
      );
    });
  }
}

/// Change history: local changes not yet confirmed by the server + the
/// server's activity log (when online).
Future<void> _showHistory(BuildContext context, WidgetRef ref, String entityId, String what) async {
  final lib = ref.read(activeLibraryProvider)!;
  final local = await ref.read(catalogActionsProvider).unconfirmedOps(entityId);
  List<ActivityEntry>? server;
  String? serverError;
  try {
    server = await ref.read(activityRepositoryProvider).historyFor(lib.id, entityId);
  } catch (e) {
    serverError = 'Sejarah pelayan tidak dapat dimuatkan (luar talian?).';
  }
  if (!context.mounted) return;
  final fmt = DateFormat('d/M/yyyy HH:mm');
  const actionLabel = {
    'create': 'Dicipta',
    'update': 'Dikemas kini',
    'soft_delete': 'Dipadam',
    'delete': 'Dipadam kekal',
    'restore': 'Dipulihkan',
    'insert': 'Dicipta',
  };
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (c, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Text('Sejarah perubahan $what', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (local.isNotEmpty) ...[
            const Text('Dalam peranti – belum disahkan pelayan', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final op in local)
              ListTile(
                dense: true,
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('${actionLabel[op.operationType] ?? op.operationType} (${op.state})'),
                subtitle: Text((jsonDecode(op.payload) as Map<String, dynamic>).keys.join(', ')),
                trailing: Text(fmt.format(op.updatedAt)),
              ),
            const Divider(),
          ],
          if (serverError != null) Text(serverError),
          if (server != null && server.isEmpty) const Text('Tiada rekod di pelayan lagi.'),
          for (final e in server ?? const <ActivityEntry>[])
            ListTile(
              dense: true,
              leading: const Icon(Icons.history),
              title: Text(actionLabel[e.action] ?? e.action),
              subtitle: e.changedFields.isEmpty ? null : Text('Medan: ${e.changedFields.join(', ')}'),
              trailing: Text(fmt.format(e.createdAt.toLocal())),
            ),
        ],
      ),
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ya')),
        ],
      ),
    ) ??
    false;
