import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/validators.dart';
import '../../../data/providers.dart';
import '../../../shared/models/library_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/members_providers.dart';

/// User management for the active library (Library Admin / Super Admin).
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(activeLibraryProvider);
    final perms = ref.watch(activePermissionsProvider);
    if (lib == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: ValueKey('members.${lib.id}'),
        drawer: const AppDrawer(),
        appBar: AppBar(
          title: Text('Pengguna – ${lib.name}'),
          bottom: const TabBar(tabs: [Tab(text: 'Ahli'), Tab(text: 'Jemputan')]),
        ),
        floatingActionButton: perms.canManageMembers
            ? FloatingActionButton.extended(
                key: const Key('members.invite'),
                onPressed: () => _showInviteDialog(context, ref, lib.id),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Jemput'),
              )
            : null,
        body: !perms.canManageMembers
            ? const Center(child: Text('Hanya Pentadbir Perpustakaan boleh mengurus pengguna.'))
            : const TabBarView(children: [_MembersTab(), _InvitationsTab()]),
      ),
    );
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider);
    return members.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(membersProvider)),
      data: (list) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(membersProvider),
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _MemberTile(member: list[i]),
        ),
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member});
  final LibraryMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(membersRepositoryProvider);
    final m = member;
    final extraEmail = m.email != m.displayName ? m.email : null;
    final statusLabel = switch (m.status) { 'active' => null, 'suspended' => 'Digantung', _ => 'Dinyahaktif' };

    Future<void> act(Future<void> Function() f, String ok) async {
      if (await runWithFeedback(context, f, success: ok)) ref.invalidate(membersProvider);
    }

    return ListTile(
      leading: CircleAvatar(child: Text(m.displayName.characters.first.toUpperCase())),
      title: Text(m.isSelf ? '${m.displayName} (anda)' : m.displayName),
      subtitle: Text([
        m.role.label,
        ?extraEmail,
        ?statusLabel,
      ].join(' • ')),
      enabled: m.isActive,
      trailing: PopupMenuButton<String>(
        tooltip: 'Tindakan',
        onSelected: (v) async {
          if (v.startsWith('role:')) {
            final role = LibraryRole.tryParse(v.substring(5))!;
            await act(() => repo.changeRole(m.memberId, role), 'Peranan ditukar kepada ${role.label}.');
          } else if (v == 'deactivate') {
            final sure = await _confirm(context, 'Nyahaktifkan ${m.displayName}?',
                'Pengguna ini akan hilang akses kepada perpustakaan serta-merta.');
            if (sure) await act(() => repo.setMembershipStatus(m.memberId, 'removed'), 'Keahlian dinyahaktifkan.');
          } else if (v == 'activate') {
            await act(() => repo.setMembershipStatus(m.memberId, 'active'), 'Keahlian diaktifkan semula.');
          }
        },
        itemBuilder: (_) => [
          for (final r in LibraryRole.values.reversed)
            if (r != m.role) PopupMenuItem(value: 'role:${r.value}', child: Text('Jadikan ${r.label}')),
          const PopupMenuDivider(),
          if (m.isActive)
            const PopupMenuItem(value: 'deactivate', child: Text('Nyahaktifkan keahlian'))
          else
            const PopupMenuItem(value: 'activate', child: Text('Aktifkan semula')),
        ],
      ),
    );
  }
}

class _InvitationsTab extends ConsumerWidget {
  const _InvitationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = ref.watch(invitationsProvider);
    final fmt = DateFormat('d MMM yyyy');
    return inv.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(invitationsProvider)),
      data: (list) => list.isEmpty
          ? const Center(child: Text('Tiada jemputan.'))
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final x = list[i];
                final status = switch (x.status) {
                  'pending' => x.isExpired ? 'Tamat tempoh' : 'Menunggu (tamat ${fmt.format(x.expiresAt)})',
                  'accepted' => 'Diterima',
                  'revoked' => 'Dibatalkan',
                  _ => 'Tamat tempoh',
                };
                return ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: Text(x.email),
                  subtitle: Text('${x.role.label} • $status'),
                  trailing: x.status == 'pending'
                      ? IconButton(
                          tooltip: 'Batalkan jemputan',
                          icon: const Icon(Icons.cancel_outlined),
                          onPressed: () async {
                            final ok = await runWithFeedback(
                                context, () => ref.read(membersRepositoryProvider).revokeInvitation(x.id),
                                success: 'Jemputan dibatalkan.');
                            if (ok) ref.invalidate(invitationsProvider);
                          },
                        )
                      : null,
                );
              },
            ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ya')),
        ],
      ),
    ) ??
    false;

Future<void> _showInviteDialog(BuildContext context, WidgetRef ref, String libraryId) async {
  final formKey = GlobalKey<FormState>();
  final email = TextEditingController();
  var role = LibraryRole.staff;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('Jemput pengguna'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('invite.email'),
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'E-mel'),
                validator: Validators.email,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<LibraryRole>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Peranan'),
                items: [
                  for (final r in LibraryRole.values) DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: (v) => setState(() => role = v ?? role),
              ),
              const SizedBox(height: 12),
              const Text('Pengguna perlu log masuk dengan e-mel ini untuk menerima jemputan.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(
            key: const Key('invite.submit'),
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(c, true);
            },
            child: const Text('Hantar jemputan'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) {
    final done = await runWithFeedback(
      context,
      () => ref.read(membersRepositoryProvider).invite(libraryId, email: email.text, role: role),
      success: 'Jemputan dicipta untuk ${email.text.trim()}.',
    );
    if (done) ref.invalidate(invitationsProvider);
  }
  // Not disposed here on purpose: the dialog's exit animation may still be
  // building the TextField. The controller has no listeners and is GC'd.
}
