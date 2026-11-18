import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/local/database/app_database.dart';
import '../../../data/providers.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../barcode/presentation/scan_field.dart';
import '../../barcode/presentation/scanner_screen.dart';
import '../../books/application/catalog_providers.dart';
import '../../libraries/application/library_context.dart';
import '../application/inventory_providers.dart';

enum BulkMode { status, relocate }

/// Scan copies one after another (camera or keyboard-wedge scanner), then
/// apply ONE change to all of them in a single transaction.
class BulkInventoryScreen extends ConsumerStatefulWidget {
  const BulkInventoryScreen({super.key, required this.mode});
  final BulkMode mode;

  @override
  ConsumerState<BulkInventoryScreen> createState() => _BulkInventoryScreenState();
}

class _BulkInventoryScreenState extends ConsumerState<BulkInventoryScreen> {
  final _scan = TextEditingController();
  final _reference = TextEditingController();
  final _remarks = TextEditingController();
  final _items = <String, (LocalBookCopy, LocalBook?)>{}; // by barcode, insertion-ordered
  CopyStatus _status = CopyStatus.damaged;
  String? _locationId;
  String? _lastMessage;
  bool _lastOk = true;
  bool _busy = false;

  @override
  void dispose() {
    _scan.dispose();
    _reference.dispose();
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _add(String raw) async {
    final code = raw.trim();
    _scan.clear();
    if (code.isEmpty) return;
    final hit = await ref.read(catalogActionsProvider).findByBarcode(code);
    if (!mounted) return;
    setState(() {
      if (hit == null) {
        _lastOk = false;
        _lastMessage = 'Barcode "$code" tidak dijumpai dalam perpustakaan ini.';
      } else if (hit.$1.deletedAt != null) {
        _lastOk = false;
        _lastMessage = 'Naskhah "$code" telah dipadam.';
      } else if (_items.containsKey(code)) {
        _lastOk = false;
        _lastMessage = '"$code" sudah ada dalam senarai.';
      } else {
        _items[code] = hit;
        _lastOk = true;
        _lastMessage = 'Ditambah: ${hit.$2?.title ?? code}';
      }
    });
  }

  Future<void> _apply() async {
    if (_items.isEmpty) return;
    if (widget.mode == BulkMode.relocate && _locationId == null) {
      showSnack(context, 'Pilih lokasi destinasi.', error: true);
      return;
    }
    final what = widget.mode == BulkMode.status ? 'status "${_status.label}"' : 'lokasi baharu';
    final sure = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Sahkan perubahan'),
            content: Text('Tetapkan $what untuk ${_items.length} naskhah?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
              FilledButton(
                  key: const Key('bulk.confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Ya')),
            ],
          ),
        ) ??
        false;
    if (!sure || !mounted) return;
    setState(() => _busy = true);
    final lib = ref.read(activeLibraryProvider)!;
    var changed = 0;
    final ok = await runWithFeedback(context, () async {
      changed = await ref.read(catalogDaoProvider).applyInventoryChange(
            lib.id,
            [for (final e in _items.values) e.$1.id],
            status: widget.mode == BulkMode.status ? _status : null,
            locationId: _locationId,
            setLocation: widget.mode == BulkMode.relocate,
            meta: MovementMeta(referenceNumber: _reference.text, remarks: _remarks.text),
          );
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(inventoryReportProvider);
      showSnack(context, '$changed naskhah dikemas kini${changed < _items.length ? ' (${_items.length - changed} sudah dalam keadaan itu)' : ''}.');
      setState(_items.clear);
      if (context.canPop()) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationsProvider).value ?? const [];
    final isStatus = widget.mode == BulkMode.status;
    return Scaffold(
      appBar: AppBar(title: Text(isStatus ? 'Tukar Status Naskhah' : 'Pindah Lokasi Naskhah')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isStatus)
            DropdownButtonFormField<CopyStatus>(
              key: const Key('bulk.status'),
              isExpanded: true,
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status baharu'),
              items: [for (final s in CopyStatus.values) DropdownMenuItem(value: s, child: Text(s.label))],
              onChanged: (v) => setState(() => _status = v ?? _status),
            )
          else
            DropdownButtonFormField<String>(
              key: const Key('bulk.location'),
              isExpanded: true,
              initialValue: _locationId,
              decoration: const InputDecoration(labelText: 'Lokasi destinasi'),
              items: [
                for (final l in locations)
                  DropdownMenuItem(value: l.id, child: Text(locationLabel(l), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _locationId = v),
            ),
          const SizedBox(height: 12),
          ScanField(
            key: const Key('bulk.scan'),
            controller: _scan,
            label: 'Imbas barcode naskhah',
            mode: ScanMode.copyBarcode,
            autofocus: true,
            helperText: 'Imbas satu demi satu. Pengimbas fizikal boleh digunakan terus.',
            onSubmitted: _add,
            onScanned: _add,
          ),
          if (_lastMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _lastMessage!,
                key: const Key('bulk.message'),
                style: TextStyle(color: _lastOk ? Colors.green.shade700 : Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Text('Naskhah dipilih: ${_items.length}', style: Theme.of(context).textTheme.titleMedium),
          for (final e in _items.entries)
            ListTile(
              key: Key('bulk.item.${e.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text('${e.key} — ${e.value.$2?.title ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(CopyStatus.parse(e.value.$1.status).label),
              trailing: IconButton(
                tooltip: 'Buang daripada senarai',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _items.remove(e.key)),
              ),
            ),
          const SizedBox(height: 12),
          TextField(controller: _reference, decoration: const InputDecoration(labelText: 'No. rujukan (pilihan)')),
          const SizedBox(height: 12),
          TextField(controller: _remarks, decoration: const InputDecoration(labelText: 'Catatan (pilihan)')),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('bulk.apply'),
            onPressed: _busy || _items.isEmpty ? null : _apply,
            child: Text('Kemas kini ${_items.length} naskhah'),
          ),
        ],
      ),
    );
  }
}
