import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/local/dao/local_dao.dart';
import '../../../data/providers.dart';
import '../../libraries/application/library_context.dart';
import '../application/sync_controller.dart';
import '../application/sync_status.dart';

/// Triggers sync automatically (spec §10 "Sync automatik"):
///  * when a library becomes active,
///  * when connectivity comes back,
///  * shortly after local changes (debounced),
///  * every few minutes while the app is open,
///  * when the app returns to the foreground.
class SyncAutoRunner extends ConsumerStatefulWidget {
  const SyncAutoRunner({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SyncAutoRunner> createState() => _SyncAutoRunnerState();
}

class _SyncAutoRunnerState extends ConsumerState<SyncAutoRunner> with WidgetsBindingObserver {
  static const _period = Duration(minutes: 3);
  static const _debounce = Duration(seconds: 3);
  Timer? _timer;
  Timer? _debounceTimer;

  bool get _enabled => ref.read(autoSyncEnabledProvider);

  void _sync() {
    if (!mounted || !_enabled || !ref.read(isOnlineProvider)) return;
    unawaited(ref.read(syncControllerProvider.notifier).syncNow());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_enabled) _timer = Timer.periodic(_period, (_) => _sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeLibraryProvider.select((l) => l?.id), (prev, next) {
      if (next != null && next != prev) _sync();
    });
    ref.listen(isOnlineProvider, (prev, next) {
      if (next && prev == false) _sync();
    });
    final libId = ref.watch(activeLibraryProvider.select((l) => l?.id));
    if (libId != null && _enabled) {
      ref.listen<AsyncValue<SyncCounts>>(syncCountsProvider(libId), (prev, next) {
        final before = prev?.value?.pending ?? 0;
        final now = next.value?.pending ?? 0;
        if (now > before) {
          _debounceTimer?.cancel();
          _debounceTimer = Timer(_debounce, _sync);
        }
      });
    }
    return widget.child;
  }
}
