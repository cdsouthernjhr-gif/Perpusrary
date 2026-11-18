import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../core/utils/barcode.dart';
import '../../../data/local/database/app_database.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../barcode/presentation/scan_field.dart';
import '../../barcode/presentation/scanner_screen.dart';
import '../../books/application/catalog_providers.dart';
import '../../books/presentation/catalog_widgets.dart';
import '../../libraries/application/library_context.dart';

/// Add or edit one physical copy.
class CopyFormScreen extends ConsumerStatefulWidget {
  const CopyFormScreen({super.key, required this.bookId, this.copyId});
  final String bookId;
  final String? copyId;

  @override
  ConsumerState<CopyFormScreen> createState() => _CopyFormScreenState();
}

class _CopyFormScreenState extends ConsumerState<CopyFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _barcode = TextEditingController();
  final _accession = TextEditingController();
  final _cost = TextEditingController();
  final _remarks = TextEditingController();
  final _reference = TextEditingController();
  CopyCondition _condition = CopyCondition.good;
  CopyStatus _status = CopyStatus.available;
  String? _locationId;
  AcquisitionSource? _source;
  DateTime? _acquired = DateTime.now();
  LocalBookCopy? _current;
  bool _saving = false;

  bool get _isEdit => widget.copyId != null;

  @override
  void initState() {
    super.initState();
    if (!_isEdit) _generate();
  }

  @override
  void dispose() {
    for (final c in [_barcode, _accession, _cost, _remarks, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    try {
      final code = await ref.read(catalogActionsProvider).generateBarcode();
      if (mounted) setState(() => _barcode.text = code);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  void _fill(LocalBookCopy c) {
    _current = c;
    _barcode.text = c.barcode;
    _accession.text = c.accessionNumber ?? '';
    _cost.text = c.acquisitionCostCents == null ? '' : (c.acquisitionCostCents! / 100).toStringAsFixed(2);
    _remarks.text = c.remarks ?? '';
    _condition = CopyCondition.parse(c.condition);
    _status = CopyStatus.parse(c.status);
    _locationId = c.locationId;
    _source = AcquisitionSource.tryParse(c.acquisitionSource);
    _acquired = c.acquisitionDate;
  }

  CopyInput get _input => CopyInput(
        barcode: CopyBarcode.normalize(_barcode.text),
        accessionNumber: _accession.text,
        condition: _condition,
        status: _status,
        locationId: _locationId,
        acquisitionDate: _acquired,
        acquisitionSource: _source,
        acquisitionCostCents: _cost.text.trim().isEmpty ? null : (double.parse(_cost.text.trim()) * 100).round(),
        remarks: _remarks.text,
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final actions = ref.read(catalogActionsProvider);
    final meta = MovementMeta(referenceNumber: _reference.text, remarks: _remarks.text);
    final ok = await saveWithBarcodeHandling(
      context,
      ref,
      () => _isEdit ? actions.updateCopy(_current!, _input, meta: meta) : actions.addCopy(widget.bookId, _input, meta: meta),
      barcode: _barcode.text.trim(),
      success: _isEdit ? 'Naskhah dikemas kini.' : 'Naskhah ditambah.',
      onGenerateNew: _isEdit ? null : _generate,
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) context.pop();
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Padam naskhah ini?'),
            content: const Text('Barcode akan kekal terpelihara dan tidak boleh digunakan semula.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Padam')),
            ],
          ),
        ) ??
        false;
    if (!sure || !mounted) return;
    final ok = await runWithFeedback(context, () => ref.read(catalogActionsProvider).deleteCopy(_current!.id),
        success: 'Naskhah dipadam.');
    if (ok && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(activePermissionsProvider);
    if (_isEdit && _current == null) {
      final copies = ref.watch(copiesProvider(widget.bookId));
      return copies.when(
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorView(error: e)),
        data: (list) {
          final hit = list.where((c) => c.copy.id == widget.copyId).map((c) => c.copy).firstOrNull;
          if (hit == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Naskhah tidak dijumpai.')));
          WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _fill(hit)));
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        },
      );
    }
    final locations = ref.watch(locationsProvider).value ?? const [];
    final canChangeBarcode = !_isEdit || perms.canEditCatalog;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Naskhah' : 'Tambah Naskhah'),
        actions: [
          if (_isEdit)
            IconButton(
              tooltip: 'Sejarah pergerakan stok',
              icon: const Icon(Icons.timeline),
              onPressed: () => context.push(Routes.copyMovements(_current!.id)),
            ),
          if (_isEdit && perms.canEditCatalog)
            IconButton(tooltip: 'Padam naskhah', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ScanField(
              key: const Key('copy.barcode'),
              controller: _barcode,
              label: 'Barcode naskhah *',
              mode: ScanMode.copyBarcode,
              enabled: canChangeBarcode,
              validator: CopyBarcode.validate,
              helperText: canChangeBarcode
                  ? 'Guna barcode sedia ada (imbas/taip) atau barcode jana sistem.'
                  : 'Hanya Editor boleh menukar barcode.',
              extraSuffix: canChangeBarcode
                  ? IconButton(tooltip: 'Jana barcode baharu', icon: const Icon(Icons.autorenew), onPressed: _generate)
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _accession,
              decoration: const InputDecoration(labelText: 'Nombor perolehan / inventori'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CopyStatus>(
                isExpanded: true,
              key: const Key('copy.status'),
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [for (final s in CopyStatus.values) DropdownMenuItem(value: s, child: Text(s.label))],
              onChanged: (v) => setState(() => _status = v ?? _status),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CopyCondition>(
                isExpanded: true,
              initialValue: _condition,
              decoration: const InputDecoration(labelText: 'Keadaan'),
              items: [for (final s in CopyCondition.values) DropdownMenuItem(value: s, child: Text(s.label))],
              onChanged: (v) => setState(() => _condition = v ?? _condition),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
                isExpanded: true,
              initialValue: locations.any((l) => l.id == _locationId) ? _locationId : null,
              decoration: const InputDecoration(labelText: 'Lokasi rak'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— Belum ditetapkan —')),
                for (final l in locations) DropdownMenuItem(value: l.id, child: Text(locationLabel(l), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _locationId = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AcquisitionSource?>(
                isExpanded: true,
              initialValue: _source,
              decoration: const InputDecoration(labelText: 'Sumber perolehan'),
              items: [
                const DropdownMenuItem(value: null, child: Text('—')),
                for (final s in AcquisitionSource.values) DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (v) => setState(() => _source = v),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tarikh perolehan'),
              subtitle: Text(_acquired == null ? '-' : DateFormat('d MMM yyyy').format(_acquired!)),
              trailing: const Icon(Icons.edit_calendar),
              onTap: () async {
                final d = await showDatePicker(
                    context: context,
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                    initialDate: _acquired ?? DateTime.now());
                if (d != null) setState(() => _acquired = d);
              },
            ),
            TextFormField(
              controller: _cost,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,10}(\.\d{0,2})?'))],
              decoration: const InputDecoration(labelText: 'Kos perolehan (RM)'),
              validator: (v) => (v == null || v.trim().isEmpty || double.tryParse(v.trim()) != null) ? null : 'Kos tidak sah.',
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _remarks, maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan')),
            const SizedBox(height: 12),
            TextFormField(controller: _reference, decoration: const InputDecoration(labelText: 'No. rujukan (pilihan)')),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('copy.save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Menyimpan…' : 'Simpan'),
            ),
          ],
        ),
      ),
    );
  }
}
