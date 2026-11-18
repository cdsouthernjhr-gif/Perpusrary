import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/validators.dart';
import '../../../data/local/database/app_database.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../books/application/catalog_providers.dart';
import '../../books/presentation/catalog_widgets.dart';
import '../../libraries/application/library_context.dart';

class LocationsScreen extends ConsumerWidget {
  const LocationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final canEdit = ref.watch(activePermissionsProvider).canEditCatalog;
    final locs = ref.watch(locationsProvider);
    return Scaffold(
      key: ValueKey('locations.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Lokasi Rak')),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('Tambah lokasi'),
            )
          : null,
      body: locs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e),
        data: (list) => list.isEmpty
            ? const Center(child: Text('Belum ada lokasi rak.'))
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final l = list[i];
                  return ListTile(
                    leading: const Icon(Icons.shelves),
                    title: Text(locationLabel(l)),
                    subtitle: l.description == null ? null : Text(l.description!),
                    trailing: SyncStateIcon(state: l.syncState),
                    onTap: canEdit ? () => _edit(context, ref, l) : null,
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, LocalLocation? l) async {
    final formKey = GlobalKey<FormState>();
    final c = {
      'building': TextEditingController(text: l?.building),
      'room': TextEditingController(text: l?.room),
      'section': TextEditingController(text: l?.section),
      'rack': TextEditingController(text: l?.rackCode),
      'shelf': TextEditingController(text: l?.shelfCode),
      'desc': TextEditingController(text: l?.description),
    };
    Widget f(String k, String label, {String? Function(String?)? v}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextFormField(controller: c[k], decoration: InputDecoration(labelText: label), validator: v),
        );
    final result = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l == null ? 'Tambah lokasi rak' : 'Edit lokasi rak'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              f('building', 'Bangunan'),
              f('room', 'Bilik'),
              f('section', 'Seksyen'),
              f('rack', 'Kod rak *', v: (x) => Validators.required(x, field: 'Kod rak')),
              f('shelf', 'Kod para'),
              f('desc', 'Keterangan'),
            ]),
          ),
        ),
        actions: [
          if (l != null) TextButton(onPressed: () => Navigator.pop(d, 'delete'), child: const Text('Padam')),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Batal')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(d, 'save');
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (!context.mounted || result == null) return;
    final actions = ref.read(catalogActionsProvider);
    if (result == 'delete') {
      await runWithFeedback(context, () => actions.deleteLocation(l!.id), success: 'Lokasi dipadam.');
    } else {
      await runWithFeedback(
        context,
        () => actions.saveLocation(
          LocationInput(
            building: c['building']!.text,
            room: c['room']!.text,
            section: c['section']!.text,
            rackCode: c['rack']!.text,
            shelfCode: c['shelf']!.text,
            description: c['desc']!.text,
          ),
          id: l?.id,
        ),
        success: 'Lokasi disimpan.',
      );
    }
  }
}
