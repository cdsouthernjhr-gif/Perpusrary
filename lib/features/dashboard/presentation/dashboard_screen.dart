import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../shared/models/dashboard_stats.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/dashboard_provider.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final perms = ref.watch(activePermissionsProvider);
    final stats = ref.watch(dashboardProvider);

    return Scaffold(
      // Keyed by library: switching library rebuilds everything from scratch.
      key: ValueKey('dashboard.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          if (perms.canEditLibrary)
            IconButton(
              tooltip: 'Edit maklumat perpustakaan',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push(Routes.libraryEdit),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(libraryContextProvider.notifier).refresh();
          ref.invalidate(dashboardProvider);
          await ref.read(dashboardProvider.future).catchError((_) => const DashboardStats(
              titleCount: 0, copyCount: 0, categoryCount: 0, locationCount: 0));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ActiveLibraryHeader(),
            const SizedBox(height: 16),
            stats.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(dashboardProvider)),
              data: (s) => _StatsBody(stats: s, isAdmin: perms.canManageMembers),
            ),
          ],
        ),
      ),
    );
  }
}

/// The active library must be unmistakable (spec §15).
class _ActiveLibraryHeader extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider)!;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                LibraryAvatar(name: lib.name, radius: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Perpustakaan aktif',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onPrimaryContainer)),
                      Text(
                        lib.name,
                        key: const Key('dashboard.libraryName'),
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                      ),
                      Text('${lib.code} • ${lib.roleLabel}',
                          style: TextStyle(color: scheme.onPrimaryContainer)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SyncIndicatorChip(libraryId: lib.id),
                if (!lib.isActive)
                  const Chip(avatar: Icon(Icons.lock_outline, size: 18), label: Text('Tidak aktif – baca sahaja')),
                FilledButton.tonalIcon(
                  key: const Key('dashboard.switch'),
                  onPressed: () async {
                    await ref.read(libraryContextProvider.notifier).clearActive();
                    if (context.mounted) context.go(Routes.libraries);
                  },
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Tukar perpustakaan'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats, required this.isAdmin});

  final DashboardStats stats;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('ms');
    final tiles = <(IconData, String, int)>[
      (Icons.menu_book, 'Jumlah judul', stats.titleCount),
      (Icons.library_books, 'Jumlah naskhah', stats.copyCount),
      (Icons.today, 'Didaftar hari ini', stats.titlesRegisteredToday + stats.copiesRegisteredToday),
      (Icons.category, 'Kategori', stats.categoryCount),
      (Icons.shelves, 'Lokasi rak', stats.locationCount),
      if (isAdmin) (Icons.group, 'Pengguna aktif', stats.activeMemberCount),
      if (isAdmin) (Icons.sync, 'Sedang sync', stats.usersSyncingNow),
      if (isAdmin) (Icons.sync_problem, 'Gagal sync (7 hari)', stats.failedSyncCount),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stats.isLocalFallback)
          const Card(
            child: ListTile(
              leading: Icon(Icons.cloud_off),
              title: Text('Statistik tempatan'),
              subtitle: Text('Pelayan tidak dapat dihubungi. Angka dikira daripada data dalam peranti ini.'),
            ),
          ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 900 ? 4 : (c.maxWidth > 560 ? 3 : 2);
          return GridView.count(
            crossAxisCount: cols,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.6,
            children: [
              for (final t in tiles)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(t.$1, color: Theme.of(context).colorScheme.primary),
                        Text(fmt.format(t.$3), style: Theme.of(context).textTheme.headlineSmall),
                        Text(t.$2, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
            ],
          );
        }),
        if (stats.copiesByStatus.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Naskhah mengikut status',
            children: [
              for (final e in stats.copiesByStatus.entries)
                ListTile(dense: true, title: Text(_statusLabel(e.key)), trailing: Text(fmt.format(e.value))),
            ],
          ),
        ],
        if (stats.byCategory.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Ringkasan mengikut kategori',
            children: [
              for (final c in stats.byCategory.take(10))
                ListTile(
                  dense: true,
                  title: Text(c.name),
                  trailing: Text('${fmt.format(c.titleCount)} judul • ${fmt.format(c.copyCount)} naskhah'),
                ),
            ],
          ),
        ],
        if (stats.recentActivity.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Aktiviti terkini',
            children: [
              for (final a in stats.recentActivity)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 20),
                  title: Text(a.label),
                  trailing: Text(DateFormat('d/M HH:mm').format(a.createdAt.toLocal())),
                ),
            ],
          ),
        ],
        if (isAdmin && stats.devices.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Peranti terakhir sync',
            children: [
              for (final d in stats.devices)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.phone_android, size: 20),
                  title: Text('Peranti ${d.deviceId.substring(0, 8)}'),
                  trailing: Text(d.lastSyncAt == null ? '-' : DateFormat('d/M HH:mm').format(d.lastSyncAt!.toLocal())),
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _statusLabel(String s) => const {
        'available': 'Tersedia',
        'in_processing': 'Dalam proses',
        'damaged': 'Rosak',
        'lost': 'Hilang',
        'inactive': 'Tidak aktif',
      }[s] ??
      s;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            ...children,
          ],
        ),
      );
}
