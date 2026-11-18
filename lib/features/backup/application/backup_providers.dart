import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/providers.dart';
import '../../../data/remote/supabase/supabase_providers.dart';
import '../../libraries/application/library_context.dart';
import '../../sync/application/sync_controller.dart';
import 'backup_service.dart';

final backupRemoteProvider = Provider<BackupRemote>((ref) => SupabaseBackupRemote(ref.watch(supabaseClientProvider)));

final backupServiceProvider =
    Provider<BackupService>((ref) => BackupService(ref.watch(syncRemoteProvider), ref.watch(backupRemoteProvider)));

final backupRecordsProvider = FutureProvider.autoDispose<List<BackupRecord>>((ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  return ref.watch(backupRemoteProvider).listRecords(lib.id);
});

String autoBackupKey(String libraryId) => 'auto_backup:$libraryId';

/// Weekly automatic backup (opt-in per library, Library Admin only), run
/// after a successful sync. Returns the record when one was made.
Future<BackupRecord?> maybeAutoBackup(Ref ref) async {
  final lib = ref.read(activeLibraryProvider);
  if (lib == null || !lib.permissions.canManageMembers) return null;
  if (await ref.read(keyValueDaoProvider).get(autoBackupKey(lib.id)) != 'on') return null;
  final records = await ref.read(backupRemoteProvider).listRecords(lib.id);
  final last = records.where((r) => r.status == 'completed' && r.backupType != 'pre_restore').firstOrNull;
  if (last != null && DateTime.now().difference(last.createdAt) < const Duration(days: 7)) return null;
  return ref.read(backupServiceProvider).create(
        libraryId: lib.id,
        libraryCode: lib.code,
        libraryName: lib.name,
        backupType: 'automatic',
      );
}
