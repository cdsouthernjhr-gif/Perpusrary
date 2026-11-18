import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/providers.dart';
import '../../../shared/models/dashboard_stats.dart';
import '../../libraries/application/library_context.dart';

/// Dashboard for the ACTIVE library. Rebuilt automatically when the library
/// changes, so statistics of the previous library are never shown.
/// Falls back to locally computed counts when the server is unreachable.
final dashboardProvider = FutureProvider.autoDispose<DashboardStats>((ref) async {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  try {
    return await ref.watch(dashboardRepositoryProvider).fetch(lib.id);
  } catch (e) {
    final failure = AppFailure.from(e);
    if (failure.code == '42501') rethrow; // access revoked: do not show cached data
    final local = await ref.watch(localDataDaoProvider).statsFor(lib.id);
    return DashboardStats(
      titleCount: local.titles,
      copyCount: local.copies,
      categoryCount: local.categories,
      locationCount: local.locations,
      isLocalFallback: true,
    );
  }
});
