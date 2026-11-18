import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/local/dao/local_dao.dart';
import 'package:smartlibrary_manager/features/sync/application/sync_status.dart';

void main() {
  SyncIndicator f({bool online = true, bool running = false, SyncCounts c = const SyncCounts()}) =>
      computeSyncIndicator(online: online, running: running, counts: c);

  test('priority: syncing > conflict > rejected > offline > failed > pending > synced', () {
    expect(f(), SyncIndicator.synced);
    expect(f(c: const SyncCounts(pending: 2)), SyncIndicator.pending);
    expect(f(online: false, c: const SyncCounts(pending: 2)), SyncIndicator.offline);
    expect(f(online: false, c: const SyncCounts(failed: 1)), SyncIndicator.offline,
        reason: 'network retries while offline are not a failure');
    expect(f(c: const SyncCounts(failed: 1)), SyncIndicator.failed);
    expect(f(online: false, c: const SyncCounts(rejected: 1)), SyncIndicator.failed);
    expect(f(c: const SyncCounts(rejected: 1)), SyncIndicator.failed);
    expect(f(c: const SyncCounts(failed: 1, conflicts: 1)), SyncIndicator.conflict);
    expect(f(running: true, c: const SyncCounts(conflicts: 1)), SyncIndicator.syncing);
  });
}
