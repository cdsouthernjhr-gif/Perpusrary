import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../data/providers.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/members_providers.dart';

class MyInvitationsScreen extends ConsumerWidget {
  const MyInvitationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = ref.watch(myInvitationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Jemputan Saya')),
      body: inv.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myInvitationsProvider)),
        data: (list) => list.isEmpty
            ? const Center(child: Text('Tiada jemputan yang menunggu.'))
            : ListView(
                children: [
                  for (final x in list)
                    Card(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: ListTile(
                        leading: const Icon(Icons.local_library),
                        title: Text(x.libraryName ?? 'Perpustakaan'),
                        subtitle: Text('Peranan: ${x.role.label}'),
                        trailing: FilledButton(
                          onPressed: () async {
                            String? libId;
                            final ok = await runWithFeedback(context, () async {
                              libId = await ref.read(membersRepositoryProvider).acceptInvitation(x.id);
                              await ref.read(libraryContextProvider.notifier).refresh();
                              await ref.read(libraryContextProvider.notifier).select(libId!);
                            }, success: 'Jemputan diterima.');
                            ref.invalidate(myInvitationsProvider);
                            if (ok && context.mounted) context.go(Routes.dashboard);
                          },
                          child: const Text('Terima'),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
