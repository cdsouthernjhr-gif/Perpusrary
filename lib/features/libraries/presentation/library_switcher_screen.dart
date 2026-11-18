import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../shared/models/library_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../users/application/members_providers.dart';
import '../application/library_context.dart';

class LibrarySwitcherScreen extends ConsumerStatefulWidget {
  const LibrarySwitcherScreen({super.key});

  @override
  ConsumerState<LibrarySwitcherScreen> createState() => _LibrarySwitcherScreenState();
}

class _LibrarySwitcherScreenState extends ConsumerState<LibrarySwitcherScreen> {
  final _search = TextEditingController();
  String _query = '';
  String? _opening;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final wasIdle = ref.read(libraryContextProvider).phase == LibraryContextPhase.idle;
      await ref.read(libraryContextProvider.notifier).initialize();
      // Session start: resume the last (re-verified) library directly.
      if (wasIdle && mounted && ref.read(activeLibraryProvider) != null) {
        context.go(Routes.dashboard);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(LibrarySummary lib) async {
    setState(() => _opening = lib.id);
    try {
      await ref.read(libraryContextProvider.notifier).select(lib.id);
      if (mounted) context.go(Routes.dashboard);
    } catch (e) {
      if (mounted) showSnack(context, AppFailure.from(e).message, error: true);
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = ref.watch(libraryContextProvider);
    final isSuper = ref.watch(isSuperAdminProvider);
    final invites = ref.watch(myInvitationsProvider).value ?? const [];
    final q = _query.toLowerCase();
    final libs = ctx.libraries
        .where((l) => q.isEmpty || l.name.toLowerCase().contains(q) || l.code.toLowerCase().contains(q))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilih Perpustakaan'),
        actions: [
          IconButton(
            tooltip: 'Jemputan saya',
            onPressed: () => context.push(Routes.invitations),
            icon: Badge(
              isLabelVisible: invites.isNotEmpty,
              label: Text('${invites.length}'),
              child: const Icon(Icons.mail_outline),
            ),
          ),
          IconButton(
            tooltip: 'Tetapan',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      floatingActionButton: isSuper
          ? FloatingActionButton.extended(
              key: const Key('switcher.add'),
              onPressed: () => context.push(Routes.libraryNew),
              icon: const Icon(Icons.add),
              label: const Text('Tambah Perpustakaan'),
            )
          : null,
      body: ctx.phase != LibraryContextPhase.ready
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await ref.read(libraryContextProvider.notifier).refresh();
                ref.invalidate(myInvitationsProvider);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  if (!ctx.verifiedWithServer)
                    Card(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const ListTile(
                        leading: Icon(Icons.cloud_off),
                        title: Text('Mod luar talian'),
                        subtitle: Text('Senarai daripada peranti ini. Akses akan disahkan semula '
                            'oleh pelayan apabila internet tersedia.'),
                      ),
                    ),
                  if (ctx.libraries.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Cari nama atau kod perpustakaan',
                        ),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                    ),
                  if (ctx.libraries.isEmpty) _EmptyState(hasInvites: invites.isNotEmpty, isSuperAdmin: isSuper),
                  for (final lib in libs)
                    _LibraryCard(
                      lib: lib,
                      busy: _opening == lib.id,
                      onTap: _opening == null ? () => _open(lib) : null,
                    ),
                ],
              ),
            ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.lib, required this.onTap, required this.busy});

  final LibrarySummary lib;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      key: Key('library.${lib.code}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              LibraryAvatar(name: lib.name, radius: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lib.name, style: t.titleMedium),
                    const SizedBox(height: 2),
                    Text('${lib.code} • ${lib.roleLabel}', style: t.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _Stat(icon: Icons.menu_book, text: '${lib.titleCount} judul'),
                        _Stat(icon: Icons.library_books, text: '${lib.copyCount} naskhah'),
                        if (!lib.isActive)
                          Chip(
                            label: const Text('Tidak aktif'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: Theme.of(context).colorScheme.errorContainer,
                          ),
                        SyncIndicatorChip(libraryId: lib.id, compact: true),
                      ],
                    ),
                  ],
                ),
              ),
              busy
                  ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 16), const SizedBox(width: 4), Text(text)],
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasInvites, required this.isSuperAdmin});
  final bool hasInvites;
  final bool isSuperAdmin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.local_library_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            isSuperAdmin
                ? 'Belum ada perpustakaan. Tekan "Tambah Perpustakaan" untuk bermula.'
                : 'Anda belum menjadi ahli mana-mana perpustakaan.\n'
                    'Minta Pentadbir Perpustakaan menjemput anda.',
            textAlign: TextAlign.center,
          ),
          if (hasInvites) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => context.push(Routes.invitations),
              icon: const Icon(Icons.mail),
              label: const Text('Lihat jemputan'),
            ),
          ],
        ],
      ),
    );
  }
}
