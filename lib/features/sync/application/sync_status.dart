import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/dao/local_dao.dart';
import '../../../data/providers.dart';

/// What the sync indicator shows (spec §15).
enum SyncIndicator { offline, syncing, conflict, failed, pending, synced }

/// True while the sync engine is running for the active library.
class SyncActivity extends Notifier<bool> {
  @override
  bool build() => false;

  void setRunning(bool running) => state = running;
}

final syncActivityProvider = NotifierProvider<SyncActivity, bool>(SyncActivity.new);

final syncCountsProvider = StreamProvider.autoDispose.family<SyncCounts, String>(
  (ref, libraryId) => ref.watch(syncQueueDaoProvider).watchCounts(libraryId),
);

/// Pure mapping (unit-tested).
SyncIndicator computeSyncIndicator({required bool online, required bool running, required SyncCounts counts}) {
  if (running) return SyncIndicator.syncing;
  if (counts.conflicts > 0) return SyncIndicator.conflict;
  if (counts.rejected > 0) return SyncIndicator.failed; // needs the user, online or not
  if (!online) return SyncIndicator.offline; // retries waiting for network
  if (counts.failed > 0) return SyncIndicator.failed;
  if (counts.pending > 0) return SyncIndicator.pending;
  return SyncIndicator.synced;
}

final syncIndicatorProvider = Provider.autoDispose.family<SyncIndicator, String>((ref, libraryId) {
  return computeSyncIndicator(
    online: ref.watch(isOnlineProvider),
    running: ref.watch(syncActivityProvider),
    counts: ref.watch(syncCountsProvider(libraryId)).value ?? const SyncCounts(),
  );
});
