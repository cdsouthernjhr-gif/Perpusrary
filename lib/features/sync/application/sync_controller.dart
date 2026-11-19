import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/dao/local_dao.dart';
import '../../../data/providers.dart';
import '../../../data/remote/supabase/supabase_providers.dart';
import '../../../data/sync/sync_engine.dart';
import '../../../data/sync/sync_remote.dart';
import '../../backup/application/backup_providers.dart';
import '../../books/application/cover_store.dart';
import '../../dashboard/application/dashboard_provider.dart';
import '../../libraries/application/library_context.dart';
import 'sync_status.dart';

final syncRemoteProvider = Provider<SyncRemote>((ref) => SupabaseSyncRemote(ref.watch(supabaseClientProvider)));

final syncEngineProvider =
    Provider<SyncEngine>((ref) => SyncEngine(ref.watch(appDatabaseProvider), ref.watch(syncRemoteProvider)));

/// Disabled in tests that do not want background syncing.
final autoSyncEnabledProvider = Provider<bool>((ref) => true);

class SyncUiState {
  const SyncUiState({this.lastReport, this.lastSyncAt, this.message});
  final SyncReport? lastReport;
  final DateTime? lastSyncAt;
  final String? message;
}

/// Runs the engine for the active library, after re-verifying the session
/// and membership with the server (spec §10: steps 2–3).
class SyncController extends Notifier<SyncUiState> {
  @override
  SyncUiState build() => const SyncUiState();

  Future<SyncReport?> syncNow() async {
    final lib = ref.read(activeLibraryProvider);
    if (lib == null) return null;
    final engine = ref.read(syncEngineProvider);
    if (engine.isRunning(lib.id)) return null;
    final activity = ref.read(syncActivityProvider.notifier);
    activity.setRunning(true);
    try {
      // Trusted re-check of membership before sending anything.
      final ctx = ref.read(libraryContextProvider.notifier);
      await ctx.refresh();
      final ctxState = ref.read(libraryContextProvider);
      if (ctxState.verifiedWithServer && !ctxState.libraries.any((l) => l.id == lib.id)) {
        state = SyncUiState(
            lastSyncAt: state.lastSyncAt, message: 'Akses anda kepada perpustakaan ini telah ditarik balik.');
        return null;
      }
      final deviceId = await ref.read(keyValueDaoProvider).get(LocalKeys.deviceId);
      final report = await engine.syncLibrary(lib.id, deviceId: deviceId);
      if (report.accessDenied) await ctx.refresh();
      state = SyncUiState(
        lastReport: report,
        lastSyncAt: report.ok ? report.finishedAt : state.lastSyncAt,
        message: report.offline
            ? 'Tiada sambungan. Perubahan disimpan dalam peranti dan akan dihantar kemudian.'
            : report.accessDenied
                ? 'Pelayan menolak akses: ${report.error}'
                : report.error,
      );
      if (report.applied > 0 || report.pulled > 0) ref.invalidate(dashboardProvider);
      if (report.ok) {
        try {
          // Cover photos taken offline (the book rows are already synced).
          await ref.read(coverStoreProvider).uploadPending(lib.id);
        } catch (_) {
          // Best effort; retried after the next sync.
        }
        try {
          await maybeAutoBackup(ref);
        } catch (_) {
          // Automatic backup is best effort; it is retried after the next sync.
        }
      }
      return report;
    } catch (e) {
      state = SyncUiState(lastSyncAt: state.lastSyncAt, message: 'Ralat sync: $e');
      return null;
    } finally {
      activity.setRunning(false);
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncUiState>(SyncController.new);
