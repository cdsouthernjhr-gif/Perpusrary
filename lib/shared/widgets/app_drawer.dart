import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/router/routes.dart';
import '../../features/libraries/application/library_context.dart';
import 'common_widgets.dart';

class _Module {
  const _Module(this.icon, this.label, {this.route, this.phase, this.visible});
  final IconData icon;
  final String label;
  final String? route;
  final int? phase; // not built yet → shown disabled with the planned phase
  final bool Function(WidgetRef ref)? visible;
}

final _modules = <_Module>[
  const _Module(Icons.dashboard_outlined, 'Dashboard', route: Routes.dashboard),
  const _Module(Icons.menu_book_outlined, 'Pengurusan Buku', route: Routes.books),
  const _Module(Icons.qr_code_scanner, 'Imbas Barcode', route: Routes.barcode),
  const _Module(Icons.library_books_outlined, 'Pengurusan Naskhah', route: Routes.copies),
  const _Module(Icons.inventory_2_outlined, 'Inventori', phase: 5),
  const _Module(Icons.category_outlined, 'Kategori', route: Routes.categories),
  const _Module(Icons.shelves, 'Lokasi Rak', route: Routes.locations),
  _Module(Icons.group_outlined, 'Pengguna',
      route: Routes.members, visible: (ref) => ref.watch(activePermissionsProvider).canManageMembers),
  const _Module(Icons.assessment_outlined, 'Laporan', phase: 7),
  const _Module(Icons.upload_file, 'Import Excel', phase: 7),
  const _Module(Icons.download, 'Eksport Excel', phase: 7),
  const _Module(Icons.sync, 'Sync Center', phase: 6),
  const _Module(Icons.backup_outlined, 'Backup', phase: 7),
  const _Module(Icons.settings_outlined, 'Tetapan', route: Routes.settings),
];

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    final current = GoRouterState.of(context).matchedLocation;
    return NavigationDrawer(
      children: [
        if (lib != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                LibraryAvatar(name: lib.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(lib.name, style: Theme.of(context).textTheme.titleMedium, maxLines: 2),
                      Text('${lib.code} • ${lib.roleLabel}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextButton.icon(
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Tukar perpustakaan'),
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(libraryContextProvider.notifier).clearActive();
              if (context.mounted) context.go(Routes.libraries);
            },
          ),
        ),
        const Divider(),
        for (final m in _modules)
          if (m.visible?.call(ref) ?? true)
            ListTile(
              leading: Icon(m.icon),
              title: Text(m.label),
              subtitle: m.phase != null ? Text('Akan datang (Fasa ${m.phase})') : null,
              enabled: m.route != null,
              selected: m.route == current,
              onTap: m.route == null
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      if (m.route != current) context.go(m.route!);
                    },
            ),
      ],
    );
  }
}
