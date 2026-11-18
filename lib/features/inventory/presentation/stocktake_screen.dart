import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/local/dao/inventory_dao.dart';
import '../../../data/local/database/app_database.dart';
import '../../../data/providers.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../barcode/presentation/scan_field.dart';
import '../../barcode/presentation/scanner_screen.dart';
import '../../books/application/catalog_providers.dart';
import '../../libraries/application/library_context.dart';
import '../application/inventory_providers.dart';

/// Shelf stocktake: pick a location, scan every copy on the shelf, then see
/// what is missing and what is on the wrong shelf. Progress is saved after
/// every scan.
class StocktakeScreen extends ConsumerStatefulWidget {
  const StocktakeScreen({super.key});

  @override
  ConsumerState<StocktakeScreen> createState() => _StocktakeScreenState();
}

class _StocktakeScreenState extends ConsumerState<StocktakeScreen> {
  final _scan = TextEditingController();
  String? _locationId;
  StocktakeState? _state;
  StocktakeScan? _last;

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  String get _lib => ref.read(activeLibraryProvider)!.id;
  InventoryDao get _dao => ref.read(inventoryDaoProvider);

  Future<void> _load() async {
    if (_locationId == null) return;
    final s = await _dao.stocktake(_lib, _locationId!);
    if (mounted) setState(() => _state = s);
  }

  Future<void> _onScan(String raw) async {
    _scan.clear();
    if (raw.trim().isEmpty || _locationId == null) return;
    final r = await _dao.scan(_lib, _locationId!, raw);
    if (r.outcome != ScanOutcome.found) unawaited(HapticFeedback.heavyImpact()); // feedback only, never block
    _last = r;
    await _load();
  }

  Future<void> _finish() async {
    final s = _state!;
    var markLost = s.missing.isNotEmpty;
    var relocate = s.unexpected.isNotEmpty;
    final go = await showDialog<bool>(
          context: context,
          builder: (c) => StatefulBuilder(
            builder: (c, set) => AlertDialog(
              title: const Text('Tamatkan semakan stok'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Dijumpai ${s.found.length} daripada ${s.expected.length}. '
                    'Tidak dijumpai: ${s.missing.length}. Rak salah: ${s.unexpected.length}.'),
                if (s.missing.isNotEmpty)
                  CheckboxListTile(
                    key: const Key('stocktake.markLost'),
                    contentPadding: EdgeInsets.zero,
                    value: markLost,
                    title: Text('Tandakan ${s.missing.length} naskhah tidak dijumpai sebagai Hilang'),
                    onChanged: (v) => set(() => markLost = v ?? false),
                  ),
                if (s.unexpected.isNotEmpty)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: relocate,
                    title: Text('Pindahkan ${s.unexpected.length} naskhah rak salah ke lokasi ini'),
                    onChanged: (v) => set(() => relocate = v ?? false),
                  ),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Kembali')),
                FilledButton(
                  key: const Key('stocktake.confirm'),
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Tamatkan'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!go || !mounted) return;
    var res = (markedLost: 0, relocated: 0);
    final ok = await runWithFeedback(context, () async {
      res = await _dao.finishStocktake(_lib, _locationId!, markMissingAsLost: markLost, relocateUnexpected: relocate);
    });
    if (!ok || !mounted) return;
    ref.invalidate(inventoryReportProvider);
    showSnack(context, 'Semakan stok selesai: ${res.markedLost} ditanda hilang, ${res.relocated} dipindahkan.');
    setState(() {
      _state = null;
      _last = null;
      _locationId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsProvider).value ?? const [];
    final s = _state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Semakan Stok'),
        actions: [
          if (s != null)
            IconButton(
              tooltip: 'Batalkan sesi',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                await _dao.cancelStocktake(_lib, _locationId!);
                setState(() {
                  _state = null;
                  _last = null;
                });
                await _load();
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            key: const Key('stocktake.location'),
            isExpanded: true,
            initialValue: _locationId,
            decoration: const InputDecoration(labelText: 'Lokasi rak yang disemak'),
            items: [
              for (final l in locations)
                DropdownMenuItem(value: l.id, child: Text(locationLabel(l), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              setState(() {
                _locationId = v;
                _state = null;
                _last = null;
              });
              _load();
            },
          ),
          if (locations.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 12), child: Text('Tambah lokasi rak dahulu (menu Lokasi Rak).')),
          if (s != null) ...[
            const SizedBox(height: 12),
            ScanField(
              key: const Key('stocktake.scan'),
              controller: _scan,
              label: 'Imbas setiap naskhah di rak',
              mode: ScanMode.copyBarcode,
              autofocus: true,
              onSubmitted: _onScan,
              onScanned: _onScan,
            ),
            if (_last != null) _LastScan(scan: _last!),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: s.expected.isEmpty ? 1 : s.found.length / s.expected.length),
            const SizedBox(height: 4),
            Text('Dijumpai ${s.found.length} / ${s.expected.length}  •  Rak salah ${s.unexpected.length}',
                key: const Key('stocktake.progress')),
            _Group(title: 'Belum dijumpai (${s.missing.length})', items: s.missing, icon: Icons.help_outline),
            _Group(title: 'Rak salah (${s.unexpected.length})', items: s.unexpected, icon: Icons.wrong_location_outlined),
            _Group(title: 'Dijumpai (${s.found.length})', items: s.found, icon: Icons.check_circle_outline),
            const SizedBox(height: 16),
            FilledButton(key: const Key('stocktake.finish'), onPressed: _finish, child: const Text('Tamatkan semakan')),
          ],
        ],
      ),
    );
  }
}

class _LastScan extends StatelessWidget {
  const _LastScan({required this.scan});
  final StocktakeScan scan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String text, Color color) = switch (scan.outcome) {
      ScanOutcome.found => ('✓ ${scan.book?.title ?? scan.barcode}', Colors.green.shade700),
      ScanOutcome.alreadyScanned => ('Sudah diimbas: ${scan.barcode}', scheme.outline),
      ScanOutcome.otherLocation => ('Rak salah: ${scan.book?.title ?? scan.barcode}', scheme.tertiary),
      ScanOutcome.unknown => ('Tidak dikenali: ${scan.barcode}', scheme.error),
      ScanOutcome.deleted => ('Naskhah dipadam: ${scan.barcode}', scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, key: const Key('stocktake.last'), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.items, required this.icon});
  final String title;
  final List<(LocalBookCopy, LocalBook)> items;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(title),
        children: [
          for (final (c, b) in items)
            ListTile(
              dense: true,
              leading: Icon(icon, size: 18),
              title: Text(c.barcode, maxLines: 1),
              subtitle: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      );
}
