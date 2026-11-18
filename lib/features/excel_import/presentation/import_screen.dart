import 'package:drift/drift.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/files/file_io.dart';
import '../../../data/local/dao/local_dao.dart';
import '../../../data/providers.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../../sync/application/sync_controller.dart';
import '../application/excel_import.dart';
import '../application/import_providers.dart';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  String? _fileName;
  Uint8List? _bytes;
  ImportOptions _options = const ImportOptions();
  ImportPlan? _plan;
  ImportResult? _result;
  String? _error;
  bool _busy = false;
  double? _progress;

  Future<void> _downloadTemplate() async {
    await runWithFeedback(context, () async {
      final saved = await ref
          .read(fileIoProvider)
          .save('Templat_Import_SmartLibrary.xlsx', buildImportTemplate(), extension: 'xlsx');
      if (!saved) throw const AppFailure('Dibatalkan.');
    }, success: 'Templat disimpan.');
  }

  Future<void> _pick() async {
    final f = await ref.read(fileIoProvider).pick(extensions: const ['xlsx']);
    if (f == null) return;
    setState(() {
      _fileName = f.$1;
      _bytes = f.$2;
      _result = null;
    });
    await _replan();
  }

  Future<void> _replan() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final lib = ref.read(activeLibraryProvider)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await ImportPlanner(ref.read(appDatabaseProvider), lib.id).plan(bytes, _fileName!, _options);
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) {
        setState(() {
          _plan = null;
          _error = e is AppFailure ? e.message : '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final plan = _plan!;
    final lib = ref.read(activeLibraryProvider)!;
    final sure = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Mulakan import?'),
            content: Text('${plan.validRows} baris sah akan diimport ke "${lib.name}". '
                '${plan.errorRows > 0 ? '${plan.errorRows} baris bermasalah akan diabaikan. ' : ''}'
                'Rekod disimpan dalam peranti dahulu dan disegerakkan ke pelayan.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
              FilledButton(key: const Key('import.confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Import')),
            ],
          ),
        ) ??
        false;
    if (!sure || !mounted) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    final jobs = ref.read(importJobRepositoryProvider);
    final jobId = await jobs.start(lib.id, plan.fileName, _options.duplicateMode.value, plan.total);
    try {
      final deviceId = await ref.read(keyValueDaoProvider).get(LocalKeys.deviceId) ?? '00000000-0000-0000-0000-000000000000';
      final result = await ImportExecutor(ref.read(appDatabaseProvider), ref.read(catalogDaoProvider),
              libraryId: lib.id, libraryCode: lib.code, deviceId: deviceId)
          .run(plan, onProgress: (d, t) {
        if (mounted) setState(() => _progress = t == 0 ? 1 : d / t);
      });
      if (jobId != null) {
        await jobs.finish(jobId,
            status: 'completed',
            ok: result.booksCreated + result.booksUpdated + result.copiesCreated + result.copiesUpdated,
            failed: result.failed + plan.errorRows,
            errors: [
              for (final r in plan.rows.where((r) => !r.ok)) {'row': r.rowNumber, 'errors': r.errors},
              for (final f in result.failures) {'row': f.$1, 'errors': [f.$2]},
            ]);
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _plan = null;
        _bytes = null;
      });
      if (ref.read(isOnlineProvider)) {
        await ref.read(syncControllerProvider.notifier).syncNow();
      }
    } catch (e) {
      if (jobId != null) await jobs.finish(jobId, status: 'failed', ok: 0, failed: plan.total);
      if (mounted) showSnack(context, AppFailure.from(e).message, error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final allowed = ref.watch(activePermissionsProvider).canEditCatalog;
    return Scaffold(
      key: ValueKey('import.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Import Excel')),
      body: !allowed
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Import memerlukan peranan Editor atau lebih tinggi.')))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text('Import ke: ${lib.name}'),
                    subtitle: const Text('Satu baris = satu naskhah. Perpustakaan TIDAK boleh ditetapkan melalui fail.'),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    key: const Key('import.template'),
                    onPressed: _busy ? null : _downloadTemplate,
                    icon: const Icon(Icons.download),
                    label: const Text('Muat turun templat'),
                  ),
                  FilledButton.icon(
                    key: const Key('import.pick'),
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file),
                    label: Text(_fileName == null ? 'Pilih fail .xlsx' : 'Pilih fail lain'),
                  ),
                ]),
                const SizedBox(height: 12),
                _Options(
                  options: _options,
                  enabled: !_busy,
                  onChanged: (o) {
                    setState(() => _options = o);
                    _replan();
                  },
                ),
                if (_progress != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress),
                ] else if (_busy)
                  const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                if (_error != null) ...[const SizedBox(height: 12), _Banner(text: _error!, error: true)],
                if (_plan != null) _Preview(plan: _plan!, busy: _busy, onImport: _import, onCancel: () => setState(() {
                      _plan = null;
                      _bytes = null;
                      _fileName = null;
                    })),
                if (_result != null) _ResultView(result: _result!),
              ],
            ),
    );
  }
}

class _Options extends StatelessWidget {
  const _Options({required this.options, required this.onChanged, required this.enabled});
  final ImportOptions options;
  final ValueChanged<ImportOptions> onChanged;
  final bool enabled;

  ImportOptions _copy({DuplicateMode? mode, bool? cats, bool? locs, bool? gen}) => ImportOptions(
        duplicateMode: mode ?? options.duplicateMode,
        createMissingCategories: cats ?? options.createMissingCategories,
        createMissingLocations: locs ?? options.createMissingLocations,
        generateMissingBarcodes: gen ?? options.generateMissingBarcodes,
      );

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), child: Text('Jika judul sudah wujud:')),
            RadioGroup<DuplicateMode>(
              groupValue: options.duplicateMode,
              onChanged: (v) => enabled && v != null ? onChanged(_copy(mode: v)) : null,
              child: Column(children: [
                for (final m in DuplicateMode.values)
                  RadioListTile<DuplicateMode>(key: Key('import.mode.${m.value}'), dense: true, value: m, title: Text(m.label)),
              ]),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Cipta kategori baharu jika tiada'),
              value: options.createMissingCategories,
              onChanged: enabled ? (v) => onChanged(_copy(cats: v)) : null,
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Cipta lokasi rak baharu jika tiada'),
              value: options.createMissingLocations,
              onChanged: enabled ? (v) => onChanged(_copy(locs: v)) : null,
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Jana barcode untuk baris tanpa barcode'),
              subtitle: const Text('Jika dimatikan, baris tanpa barcode hanya mendaftar judul.'),
              value: options.generateMissingBarcodes,
              onChanged: enabled ? (v) => onChanged(_copy(gen: v)) : null,
            ),
          ]),
        ),
      );
}

class _Preview extends StatelessWidget {
  const _Preview({required this.plan, required this.busy, required this.onImport, required this.onCancel});
  final ImportPlan plan;
  final bool busy;
  final VoidCallback onImport;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final problems = plan.rows.where((r) => !r.ok || r.warnings.isNotEmpty).toList();
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text('Pratonton: ${plan.fileName}', style: t.titleMedium),
        for (final w in plan.fileWarnings) _Banner(text: w),
        Card(
          key: const Key('import.summary'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 16, runSpacing: 4, children: [
              Text('Baris: ${plan.total}'),
              Text('Sah: ${plan.validRows}'),
              Text('Ralat: ${plan.errorRows}', style: TextStyle(color: plan.errorRows > 0 ? Theme.of(context).colorScheme.error : null)),
              Text('Diabaikan (pendua): ${plan.skippedRows}'),
              Text('Judul baharu: ${plan.newBooks}'),
              Text('Naskhah baharu: ${plan.newCopies}'),
              Text('Judul dikemas kini: ${plan.updatedBooks}'),
              Text('Naskhah dikemas kini: ${plan.updatedCopies}'),
              Text('Kategori baharu: ${plan.newCategories.length}'),
              Text('Lokasi baharu: ${plan.newLocations.length}'),
            ]),
          ),
        ),
        if (problems.isNotEmpty) ...[
          Text('Baris bermasalah / amaran (${problems.length})', style: t.titleSmall),
          for (final r in problems.take(300))
            ListTile(
              dense: true,
              key: Key('import.row.${r.rowNumber}'),
              leading: Icon(r.ok ? Icons.warning_amber : Icons.error_outline,
                  color: r.ok ? Theme.of(context).colorScheme.tertiary : Theme.of(context).colorScheme.error),
              title: Text('Baris ${r.rowNumber}'),
              subtitle: Text([...r.errors, ...r.warnings].join('\n')),
            ),
          if (problems.length > 300) Text('… dan ${problems.length - 300} lagi.'),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('Batal'))),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              key: const Key('import.run'),
              onPressed: busy || plan.validRows == 0 ? null : onImport,
              child: Text('Import ${plan.validRows} baris'),
            ),
          ),
        ]),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result});
  final ImportResult result;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('import.result'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Import selesai', style: Theme.of(context).textTheme.titleMedium),
            Text('Judul baharu: ${result.booksCreated} • Judul dikemas kini: ${result.booksUpdated}'),
            Text('Naskhah baharu: ${result.copiesCreated} • Naskhah dikemas kini: ${result.copiesUpdated}'),
            Text('Diabaikan: ${result.skipped} • Gagal: ${result.failed}'),
            for (final f in result.failures.take(50)) Text('Baris ${f.$1}: ${f.$2}'),
            const SizedBox(height: 4),
            const Text('Rekod akan dihantar ke pelayan oleh sync (lihat Sync Center).'),
          ]),
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Card(
      color: error ? s.errorContainer : s.tertiaryContainer,
      child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
    );
  }
}
