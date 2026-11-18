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

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final canEdit = ref.watch(activePermissionsProvider).canEditCatalog;
    final cats = ref.watch(categoriesProvider);
    return Scaffold(
      key: ValueKey('categories.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Kategori')),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: const Key('categories.add'),
              onPressed: () => _edit(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('Tambah kategori'),
            )
          : null,
      body: cats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e),
        data: (list) => list.isEmpty
            ? const Center(child: Text('Belum ada kategori.'))
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = list[i];
                  return ListTile(
                    leading: const Icon(Icons.category_outlined),
                    title: Text(c.name),
                    subtitle: Text([if (c.code != null) c.code!, if (c.description != null) c.description!].join(' • ')),
                    trailing: SyncStateIcon(state: c.syncState),
                    onTap: canEdit ? () => _edit(context, ref, c) : null,
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, LocalCategory? c) async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: c?.name);
    final code = TextEditingController(text: c?.code);
    final desc = TextEditingController(text: c?.description);
    final result = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(c == null ? 'Tambah kategori' : 'Edit kategori'),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
                key: const Key('category.name'),
                controller: name,
                decoration: const InputDecoration(labelText: 'Nama *'),
                validator: (v) => Validators.required(v, field: 'Nama')),
            const SizedBox(height: 12),
            TextFormField(controller: code, decoration: const InputDecoration(labelText: 'Kod (cth. DDC 813)')),
            const SizedBox(height: 12),
            TextFormField(controller: desc, decoration: const InputDecoration(labelText: 'Keterangan')),
          ]),
        ),
        actions: [
          if (c != null) TextButton(onPressed: () => Navigator.pop(d, 'delete'), child: const Text('Padam')),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Batal')),
          FilledButton(
            key: const Key('category.save'),
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
      await runWithFeedback(context, () => actions.deleteCategory(c!.id), success: 'Kategori dipadam.');
    } else {
      await runWithFeedback(
        context,
        () => actions.saveCategory(CategoryInput(name: name.text, code: code.text, description: desc.text), id: c?.id),
        success: 'Kategori disimpan.',
      );
    }
  }
}
