import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/local/dao/local_dao.dart';
import '../../../data/providers.dart';
import '../../../data/remote/supabase/supabase_providers.dart';
import '../../../shared/models/library_models.dart';

const appVersion = '1.0.0';

enum LibraryContextPhase { idle, loading, ready }

class LibraryContextState {
  const LibraryContextState({
    this.phase = LibraryContextPhase.idle,
    this.userId,
    this.libraries = const [],
    this.active,
    this.verifiedWithServer = false,
    this.isSuperAdmin = false,
    this.lastError,
  });

  final LibraryContextPhase phase;
  final String? userId;
  final List<LibrarySummary> libraries;
  final LibrarySummary? active;

  /// True when the library list was confirmed by the server in this session.
  /// False = working from the device cache (offline); the server still
  /// enforces access on every sync.
  final bool verifiedWithServer;

  /// From public.system_admins (server); false while offline.
  final bool isSuperAdmin;
  final String? lastError;

  LibraryContextState copyWith({
    LibraryContextPhase? phase,
    String? userId,
    List<LibrarySummary>? libraries,
    LibrarySummary? Function()? active,
    bool? verifiedWithServer,
    bool? isSuperAdmin,
    String? Function()? lastError,
  }) =>
      LibraryContextState(
        phase: phase ?? this.phase,
        userId: userId ?? this.userId,
        libraries: libraries ?? this.libraries,
        active: active != null ? active() : this.active,
        verifiedWithServer: verifiedWithServer ?? this.verifiedWithServer,
        isSuperAdmin: isSuperAdmin ?? this.isSuperAdmin,
        lastError: lastError != null ? lastError() : this.lastError,
      );
}

/// Owns "which library am I working in".
///
/// Rules (spec §3.2):
///  1. The cached last library is only a hint; on every session start the
///     list is re-fetched from `my_libraries()` (trusted source) when online.
///  2. Switching re-verifies membership before changing context.
///  3. Libraries the user lost access to are purged from the device.
///  4. A different user signing in on the same device wipes the previous
///     user's local data.
///  5. Every per-library provider watches [activeLibraryProvider], so data of
///     the previous library is discarded when the context changes.
class LibraryContextController extends Notifier<LibraryContextState> {
  @override
  LibraryContextState build() => const LibraryContextState();

  KeyValueDao get _kv => ref.read(keyValueDaoProvider);
  LibrariesDao get _libs => ref.read(librariesDaoProvider);

  /// Idempotent per user. Call when an authenticated screen opens.
  Future<void> initialize() async {
    final userId = ref.read(authRepositoryProvider).currentUser?.id;
    if (userId == null) {
      state = const LibraryContextState();
      return;
    }
    if (state.userId == userId && state.phase != LibraryContextPhase.idle) return;

    state = LibraryContextState(phase: LibraryContextPhase.loading, userId: userId);

    // (4) Device used by another account before → wipe its local data.
    final owner = await _kv.get(LocalKeys.ownerUserId);
    if (owner != null && owner != userId) {
      await ref.read(localDataDaoProvider).wipeAllUserData();
    }
    await _kv.put(LocalKeys.ownerUserId, userId);

    await _registerDevice();
    await refresh();

    // Restore the last library only if it is still accessible.
    final lastId = await _kv.get(LocalKeys.activeLibraryId);
    final last = _find(lastId);
    state = state.copyWith(phase: LibraryContextPhase.ready, active: () => last);
    if (last == null && lastId != null) await _kv.remove(LocalKeys.activeLibraryId);
  }

  /// Re-fetches the authoritative library list. Falls back to the cache when
  /// the server cannot be reached.
  Future<void> refresh() async {
    try {
      final repo = ref.read(libraryRepositoryProvider);
      final remote = await repo.fetchMyLibraries();
      final superAdmin = await repo.isSuperAdmin();
      final accessible = remote.where((l) => l.hasAccess).toList();
      await _libs.replaceWithServerList(accessible, DateTime.now());
      final hadActive = state.active != null;
      final stillActive = hadActive ? _findIn(accessible, state.active!.id) : null;
      state = state.copyWith(
        libraries: accessible,
        verifiedWithServer: true,
        isSuperAdmin: superAdmin,
        active: () => stillActive,
        lastError: () => null,
      );
      // Only forget the saved choice when the active library was revoked;
      // during initialize() nothing is active yet and the hint must survive.
      if (hadActive && stillActive == null) await _kv.remove(LocalKeys.activeLibraryId);
    } catch (e) {
      final cached = await _libs.getAll();
      state = state.copyWith(
        libraries: cached,
        verifiedWithServer: false,
        isSuperAdmin: false,
        lastError: () => AppFailure.from(e).message,
      );
    }
  }

  /// Switches the active library after verifying membership (spec §3.2.1).
  Future<void> select(String libraryId) async {
    if (ref.read(isOnlineProvider)) {
      await refresh(); // trusted re-verification when possible
    }
    final lib = _find(libraryId);
    if (lib == null || !lib.hasAccess) {
      throw const AppFailure('Anda tiada akses kepada perpustakaan ini.', code: 'no_membership');
    }
    state = state.copyWith(active: () => lib);
    await _kv.put(LocalKeys.activeLibraryId, lib.id);
  }

  /// Leaves the current library (back to the switcher).
  Future<void> clearActive() async {
    state = state.copyWith(active: () => null);
    await _kv.remove(LocalKeys.activeLibraryId);
  }

  /// Call before signing out. Local data stays for the same user (offline
  /// work); it is wiped if another user signs in next.
  void reset() => state = const LibraryContextState();

  LibrarySummary? _find(String? id) => id == null ? null : _findIn(state.libraries, id);

  static LibrarySummary? _findIn(List<LibrarySummary> list, String id) {
    for (final l in list) {
      if (l.id == id) return l;
    }
    return null;
  }

  Future<void> _registerDevice() async {
    var deviceId = await _kv.get(LocalKeys.deviceId);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await _kv.put(LocalKeys.deviceId, deviceId);
    }
    try {
      await ref.read(deviceRepositoryProvider).register(
            deviceId: deviceId,
            deviceName: 'Android ${deviceId.substring(0, 8)}',
            appVersion: appVersion,
          );
    } catch (_) {
      // Offline or transient: registration is retried next session.
    }
  }
}

final libraryContextProvider =
    NotifierProvider<LibraryContextController, LibraryContextState>(LibraryContextController.new);

/// The active library. Per-library providers MUST watch this.
final activeLibraryProvider = Provider<LibrarySummary?>(
  (ref) => ref.watch(libraryContextProvider.select((s) => s.active)),
);

final activePermissionsProvider = Provider<LibraryPermissions>((ref) {
  final lib = ref.watch(activeLibraryProvider);
  return lib?.permissions ?? const LibraryPermissions(role: null, isSuperAdmin: false, libraryActive: false);
});

final isSuperAdminProvider = Provider<bool>(
  (ref) => ref.watch(libraryContextProvider.select((s) => s.isSuperAdmin)),
);
