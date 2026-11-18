import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/files/file_io.dart';
import '../../../data/providers.dart';
import '../../../data/remote/supabase/supabase_providers.dart';
import '../../../data/repositories/library_repositories.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../../sync/application/sync_controller.dart';
import '../../sync/application/sync_status.dart';
import '../application/excel_export.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _busy = false;
  String? _done;

  Future<void> _export() async {
    final lib = ref.read(activeLibraryProvider)!;
    setState(() {
      _busy = true;
      _done = null;
    });
    final ok = await runWithFeedback(context, () async {
      final online = ref.read(isOnlineProvider);
      if (online) await ref.read(syncControllerProvider.notifier).syncNow(); // freshest data first
      List<ActivityEntry>? activity;
      var names = <String, String>{};
      if (online) {
        try {
          final repo = ref.read(activityRepositoryProvider);
          activity = await repo.libraryFeed(lib.id, limit: 1000);
          names = await repo.userNames(activity.map((a) => a.userId).whereType<String>().toSet());
        } catch (_) {
          activity = null;
        }
      }
      final now = DateTime.now();
      final user = ref.read(authRepositoryProvider).currentUser;
      final bytes = await ExcelExporter(ref.read(appDatabaseProvider)).build(
        libraryId: lib.id,
        libraryName: lib.name,
        libraryCode: lib.code,
        exportedAt: now,
        exportedBy: user?.email,
        activity: activity,
        userNames: names,
      );
      final name = ExcelExporter.fileName(lib.code, now);
      final saved = await ref.read(fileIoProvider).save(name, bytes, extension: 'xlsx');
      if (!saved) throw const AppFailure('Dibatalkan.');
      setState(() => _done = name);
    }, success: 'Fail Excel disimpan.');
    if (mounted) setState(() => _busy = false);
    if (!ok) return;
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final counts = ref.watch(syncCountsProvider(lib.id)).value;
    return Scaffold(
      key: ValueKey('export.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Eksport Excel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.table_view),
              title: Text('Eksport: ${lib.name}'),
              subtitle: const Text('Satu fail .xlsx dengan 8 worksheet: Ringkasan, Katalog Buku, Naskhah, Kategori, '
                  'Lokasi Rak, Kemasukan, Barcode dan Aktiviti. Hanya data perpustakaan ini.'),
            ),
          ),
          if ((counts?.pending ?? 0) > 0 || (counts?.hasProblems ?? false))
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text('${counts!.pending} perubahan belum disegerakkan'),
                subtitle: const Text('Sync akan dicuba dahulu. Data yang belum sync tetap dimasukkan dan ditanda dalam fail.'),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('export.run'),
            onPressed: _busy ? null : _export,
            icon: _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download),
            label: const Text('Jana & simpan fail Excel'),
          ),
          if (_done != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text('Disimpan: $_done', key: const Key('export.done'))),
        ],
      ),
    );
  }
}
