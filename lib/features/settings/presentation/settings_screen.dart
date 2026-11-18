import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/validators.dart';
import '../../../data/providers.dart';
import '../../../data/remote/supabase/supabase_providers.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';

final _profileProvider = FutureProvider.autoDispose((ref) => ref.watch(profileRepositoryProvider).getMine());

/// Profile + account settings + logout.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _filled = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    final unsynced = await ref.read(syncQueueDaoProvider).unsyncedCount();
    if (!mounted) return;
    final sure = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Log keluar?'),
            content: Text(unsynced > 0
                ? 'AMARAN: $unsynced perubahan belum disegerakkan ke pelayan. Ia kekal dalam peranti ini '
                    'dan akan dihantar apabila anda log masuk semula — tetapi akan DIPADAM jika pengguna '
                    'lain log masuk pada peranti ini.'
                : 'Anda perlu log masuk semula untuk menggunakan aplikasi.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Log keluar')),
            ],
          ),
        ) ??
        false;
    if (!sure || !mounted) return;
    ref.read(libraryContextProvider.notifier).reset();
    await runWithFeedback(context, () => ref.read(authRepositoryProvider).signOut());
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(_profileProvider);
    final hasLibrary = ref.watch(activeLibraryProvider) != null;
    final ctx = ref.watch(libraryContextProvider);
    return Scaffold(
      drawer: hasLibrary ? const AppDrawer() : null,
      appBar: AppBar(title: const Text('Tetapan')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Profil', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          profile.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_profileProvider)),
            data: (p) {
              if (!_filled) {
                _name.text = p.fullName ?? '';
                _phone.text = p.phone ?? '';
                _filled = true;
              }
              return Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.email_outlined),
                      title: Text(p.email ?? '-'),
                      subtitle: const Text('E-mel log masuk'),
                    ),
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Nama penuh'),
                      validator: (v) => Validators.required(v, field: 'Nama'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Telefon'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () async {
                        if (!(_formKey.currentState?.validate() ?? false)) return;
                        await runWithFeedback(
                          context,
                          () => ref.read(profileRepositoryProvider).updateMine(fullName: _name.text, phone: _phone.text),
                          success: 'Profil disimpan.',
                        );
                      },
                      child: const Text('Simpan profil'),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(ctx.verifiedWithServer ? Icons.verified_user_outlined : Icons.cloud_off),
            title: Text(ctx.verifiedWithServer ? 'Akses disahkan oleh pelayan' : 'Belum disahkan (luar talian)'),
            subtitle: Text('${ctx.libraries.length} perpustakaan boleh diakses'
                '${ctx.isSuperAdmin ? ' • Super Admin' : ''}'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('settings.logout'),
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            label: const Text('Log keluar'),
          ),
        ],
      ),
    );
  }
}
