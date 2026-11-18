import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../data/local/database/app_database.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../books/application/catalog_providers.dart';
import '../../books/presentation/catalog_widgets.dart';
import 'scan_field.dart';
import 'scanner_screen.dart';

/// Find a physical copy by barcode — camera, typing, or a keyboard-wedge
/// scanner (the field keeps focus so staff can scan item after item).
class BarcodeLookupScreen extends ConsumerStatefulWidget {
  const BarcodeLookupScreen({super.key});

  @override
  ConsumerState<BarcodeLookupScreen> createState() => _BarcodeLookupScreenState();
}

class _BarcodeLookupScreenState extends ConsumerState<BarcodeLookupScreen> {
  final _controller = TextEditingController();
  (LocalBookCopy, LocalBook?)? _result;
  String? _notFound;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _lookup(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    final hit = await ref.read(catalogActionsProvider).findByBarcode(code);
    if (!mounted) return;
    setState(() {
      _result = hit;
      _notFound = hit == null ? code : null;
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Cari Naskhah (Barcode)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ScanField(
            key: const Key('lookup.field'),
            controller: _controller,
            label: 'Imbas atau taip barcode',
            mode: ScanMode.copyBarcode,
            autofocus: true,
            helperText: 'Pengimbas barcode fizikal (USB/Bluetooth) boleh digunakan terus di sini.',
            onSubmitted: _lookup,
            onScanned: _lookup,
          ),
          const SizedBox(height: 16),
          if (_notFound != null)
            Card(
              key: const Key('lookup.notFound'),
              child: ListTile(
                leading: const Icon(Icons.search_off),
                title: Text('Barcode "$_notFound" tidak dijumpai'),
                subtitle: const Text('Tiada naskhah dengan barcode ini dalam perpustakaan aktif (data peranti ini).'),
              ),
            ),
          if (r != null)
            Card(
              key: const Key('lookup.result'),
              child: ListTile(
                leading: BookCover(url: r.$2?.coverImagePath, size: 40),
                title: Text(r.$2?.title ?? '(Judul tidak dijumpai)'),
                subtitle: Text([
                  r.$1.barcode,
                  CopyStatus.parse(r.$1.status).label,
                  if (r.$1.deletedAt != null) 'NASKHAH DIPADAM',
                ].join(' • ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: r.$2 == null ? null : () => context.push(Routes.book(r.$2!.id)),
              ),
            ),
        ],
      ),
    );
  }
}
