import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/providers.dart';
import '../../../shared/models/library_models.dart';
import '../../libraries/application/library_context.dart';

String _activeId(Ref ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  return lib.id;
}

final membersProvider = FutureProvider.autoDispose<List<LibraryMember>>(
  (ref) => ref.watch(membersRepositoryProvider).listMembers(_activeId(ref)),
);

final invitationsProvider = FutureProvider.autoDispose<List<LibraryInvitation>>(
  (ref) => ref.watch(membersRepositoryProvider).listInvitations(_activeId(ref)),
);

/// Invitations addressed to the signed-in user (any library).
final myInvitationsProvider = FutureProvider.autoDispose<List<LibraryInvitation>>(
  (ref) => ref.watch(membersRepositoryProvider).myPendingInvitations(),
);
