import 'package:drift/drift.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/files/file_io.dart';
import '../../../data/providers.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../../sync/application/sync_controller.dart';
import '../application/backup_providers.dart';
import '../application/backup_service.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  bool? _auto;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final lib = ref.read(activeLibraryProvider);
      if (lib == null) return;
      final v = await ref.read(keyValueDaoProvider).get(autoBackupKey(lib.id));
      if (mounted) setState(() => _auto = v == 'on');
    });
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(context, f, success: done);
    if (mounted) setState(() => _busy = false);
    if (ok) ref.invalidate(backupRecordsProvider);
  }

  Future<void> _backupNow() {
    final lib = ref.read(activeLibraryProvider)!;
    return _run(() async {
      await ref.read(syncControllerProvider.notifier).syncNow(); // include this device's pending changes
      await ref.read(backupServiceProvider).create(libraryId: lib.id, libraryCode: lib.code, libraryName: lib.name);
    }, 'Backup berjaya disimpan di pelayan.');
  }

  Future<void> _exportFile(BackupRecord r) => _run(() async {
        final bytes = await ref.read(backupServiceProvider).download(r);
        final name = 'Backup_${ref.read(activeLibraryProvider)!.code}_${DateFormat('yyyyMMdd_HHmm').format(r.createdAt.toLocal())}.json.gz';
        if (!await ref.read(fileIoProvider).save(name, bytes, extension: 'gz')) throw const AppFailure('Dibatalkan.');
      }, 'Fail backup disimpan.');

  Future<void> _restoreFromRecord(BackupRecord r) async {
    try {
      final bytes = await ref.read(backupServiceProvider).download(r);
      if (mounted) await _restoreBytes(bytes);
    } catch (e) {
      if (mounted) showSnack(context, AppFailure.from(e).message, error: true);
    }
  }

  Future<void> _restoreFromFile() async {
    final f = await ref.read(fileIoProvider).pick(extensions: const ['gz', 'json']);
    if (f == null || !mounted) return;
    await _restoreBytes(f.$2);
  }

  Future<void> _restoreBytes(Uint8List bytes) async {
    final lib = ref.read(activeLibraryProvider)!;
    final BackupSummary summary;
    try {
      summary = BackupService.validate(bytes, lib.id);
    } catch (e) {
      showSnack(context, AppFailure.from(e).message, error: true);
      return;
    }
    final deleteMissing = await showDialog<bool>(
      context: context,
      builder: (_) => _RestoreDialog(libraryName: lib.name, libraryCode: lib.code, summary: summary),
    );
    if (deleteMissing == null || !mounted) return;
    await _run(() async {
      await ref.read(backupServiceProvider).restore(summary,
          libraryCode: lib.code, libraryName: lib.name, deleteMissing: deleteMissing);
      await ref.read(syncControllerProvider.notifier).syncNow();
    }, 'Restore selesai. Data peranti disegerakkan.');
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final allowed = ref.watch(activePermissionsProvider).canManageMembers;
    final online = ref.watch(isOnlineProvider);
    final records = ref.watch(backupRecordsProvider);
    final fmt = DateFormat('d/M/yyyy HH:mm');
    const typeLabel = {'manual': 'Manual', 'automatic': 'Automatik', 'pre_restore': 'Sebelum restore'};
    const statusLabel = {'completed': 'Berjaya', 'pending': 'Dalam proses', 'failed': 'Gagal'};
    return Scaffold(
      key: ValueKey('backup.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: !allowed
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Hanya Pentadbir Perpustakaan boleh mengurus backup.')))
          : !online
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Backup disimpan di pelayan. Sambung ke internet untuk meneruskan.')))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                        key: const Key('backup.now'),
                        onPressed: _busy ? null : _backupNow,
                        icon: const Icon(Icons.backup),
                        label: const Text('Backup sekarang'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('backup.restoreFile'),
                        onPressed: _busy ? null : _restoreFromFile,
                        icon: const Icon(Icons.restore_page_outlined),
                        label: const Text('Restore daripada fail'),
                      ),
                    ]),
                    if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Backup automatik mingguan'),
                      subtitle: const Text('Dibuat selepas sync apabila backup terakhir lebih 7 hari.'),
                      value: _auto ?? false,
                      onChanged: _auto == null
                          ? null
                          : (v) async {
                              await ref.read(keyValueDaoProvider).put(autoBackupKey(lib.id), v ? 'on' : 'off');
                              setState(() => _auto = v);
                            },
                    ),
                    const Divider(),
                    Text('Sejarah backup', style: Theme.of(context).textTheme.titleMedium),
                    records.when(
                      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
                      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(backupRecordsProvider)),
                      data: (list) => list.isEmpty
                          ? const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada backup.'))
                          : Column(children: [
                              for (final r in list)
                                Card(
                                  key: Key('backup.${r.id}'),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text('${fmt.format(r.createdAt.toLocal())} • ${typeLabel[r.backupType] ?? r.backupType}',
                                          style: Theme.of(context).textTheme.titleSmall),
                                      Text('${statusLabel[r.status] ?? r.status}'
                                          '${r.fileSize == null ? '' : ' • ${(r.fileSize! / 1024).toStringAsFixed(1)} KB'}'
                                          '${r.recordCounts.isEmpty ? '' : ' • ${r.recordCounts['books'] ?? 0} judul, ${r.recordCounts['book_copies'] ?? 0} naskhah'}'),
                                      if (r.status == 'completed')
                                        Wrap(spacing: 8, children: [
                                          TextButton.icon(
                                            onPressed: _busy ? null : () => _exportFile(r),
                                            icon: const Icon(Icons.download, size: 18),
                                            label: const Text('Simpan fail'),
                                          ),
                                          TextButton.icon(
                                            key: Key('backup.restore.${r.id}'),
                                            onPressed: _busy ? null : () => _restoreFromRecord(r),
                                            icon: const Icon(Icons.restore, size: 18),
                                            label: const Text('Restore'),
                                          ),
                                        ]),
                                    ]),
                                  ),
                                ),
                            ]),
                    ),
                  ],
                ),
    );
  }
}

/// Confirmation dialog: shows what will be restored and requires typing the
/// library code. Pops with `deleteMissing` (bool) or null when cancelled.
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({required this.libraryName, required this.libraryCode, required this.summary});
  final String libraryName;
  final String libraryCode;
  final BackupSummary summary;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _code = TextEditingController(); // owned here: disposed only when the dialog is gone
  bool _deleteMissing = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    return AlertDialog(
      key: const Key('restore.dialog'),
      icon: const Icon(Icons.restore),
      title: const Text('Sahkan restore'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Perpustakaan: ${widget.libraryName} (${widget.libraryCode})'),
          Text('Tarikh backup: ${s.createdAt == null ? '-' : DateFormat('d/M/yyyy HH:mm').format(s.createdAt!.toLocal())}'),
          Text('Kategori ${s.counts['categories']} • Lokasi ${s.counts['locations']} • '
              'Judul ${s.counts['books']} • Naskhah ${s.counts['book_copies']}'),
          const SizedBox(height: 8),
          const Text('Rekod dalam backup akan dipulihkan. Backup keadaan semasa dibuat secara automatik '
              'dahulu. Sejarah pergerakan stok tidak diubah.'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _deleteMissing,
            onChanged: (v) => setState(() => _deleteMissing = v ?? false),
            title: const Text('Padam (soft delete) rekod yang tiada dalam backup'),
          ),
          TextField(
            key: const Key('restore.code'),
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: 'Taip kod perpustakaan (${widget.libraryCode}) untuk sahkan'),
            onChanged: (_) => setState(() {}),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          key: const Key('restore.confirm'),
          onPressed: _code.text.trim().toUpperCase() == widget.libraryCode
              ? () => Navigator.pop(context, _deleteMissing)
              : null,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
