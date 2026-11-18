import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/remote/supabase/supabase_providers.dart';

/// TEMPORARY (Phase 2): proves sign-in + server-side membership filtering by
/// listing my_libraries() straight from Supabase. Replaced in Phase 3 by the
/// offline-capable Library Switcher backed by Drift.
class LibrarySwitcherPlaceholder extends ConsumerStatefulWidget {
  const LibrarySwitcherPlaceholder({super.key});

  @override
  ConsumerState<LibrarySwitcherPlaceholder> createState() => _State();
}

class _State extends ConsumerState<LibrarySwitcherPlaceholder> {
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final rows = await ref.read(supabaseClientProvider).rpc<List<dynamic>>('my_libraries');
      return rows.cast<Map<String, dynamic>>();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authRepositoryProvider).currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilih Perpustakaan'),
        actions: [
          IconButton(
            tooltip: 'Log keluar',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _future = _load()),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              final msg = snap.error is AppFailure ? (snap.error! as AppFailure).message : '${snap.error}';
              return ListView(children: [ListTile(leading: const Icon(Icons.error_outline), title: Text(msg))]);
            }
            final libs = snap.data!;
            if (libs.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text('Log masuk sebagai ${user?.email ?? '-'}'),
                  const SizedBox(height: 12),
                  const Text('Anda belum menjadi ahli mana-mana perpustakaan. '
                      'Minta Pentadbir Perpustakaan menjemput anda.'),
                ],
              );
            }
            return ListView.separated(
              itemCount: libs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final l = libs[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.local_library)),
                  title: Text('${l['name']}'),
                  subtitle: Text('${l['code']} • ${l['role'] ?? 'super admin'} • '
                      '${l['title_count']} judul • ${l['copy_count']} naskhah'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
