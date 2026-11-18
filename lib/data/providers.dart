import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local/dao/catalog_dao.dart';
import 'local/dao/inventory_dao.dart';
import 'local/dao/local_dao.dart';
import 'local/database/app_database.dart';
import 'remote/book_metadata_service.dart';
import 'remote/supabase/supabase_providers.dart';
import 'repositories/library_repositories.dart';

/// Overridden in main.dart with the on-device database (and in tests with an
/// in-memory one).
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('appDatabaseProvider must be overridden'),
);

final keyValueDaoProvider = Provider((ref) => KeyValueDao(ref.watch(appDatabaseProvider)));
final librariesDaoProvider = Provider((ref) => LibrariesDao(ref.watch(appDatabaseProvider)));
final syncQueueDaoProvider = Provider((ref) => SyncQueueDao(ref.watch(appDatabaseProvider)));
final localDataDaoProvider = Provider((ref) => LocalDataDao(ref.watch(appDatabaseProvider)));
final catalogDaoProvider = Provider((ref) => CatalogDao(ref.watch(appDatabaseProvider)));
final inventoryDaoProvider =
    Provider((ref) => InventoryDao(ref.watch(appDatabaseProvider), ref.watch(catalogDaoProvider)));

final bookMetadataServiceProvider = Provider((ref) => BookMetadataService());

final activityRepositoryProvider =
    Provider<ActivityRepository>((ref) => SupabaseActivityRepository(ref.watch(supabaseClientProvider)));

final libraryRepositoryProvider =
    Provider<LibraryRepository>((ref) => SupabaseLibraryRepository(ref.watch(supabaseClientProvider)));
final membersRepositoryProvider =
    Provider<MembersRepository>((ref) => SupabaseMembersRepository(ref.watch(supabaseClientProvider)));
final dashboardRepositoryProvider =
    Provider<DashboardRepository>((ref) => SupabaseDashboardRepository(ref.watch(supabaseClientProvider)));
final profileRepositoryProvider =
    Provider<ProfileRepository>((ref) => SupabaseProfileRepository(ref.watch(supabaseClientProvider)));
final deviceRepositoryProvider =
    Provider<DeviceRepository>((ref) => SupabaseDeviceRepository(ref.watch(supabaseClientProvider)));

/// Network availability *hint* from the OS. A request may still fail while
/// "online"; callers always handle errors and fall back to local data.
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool online(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  yield online(await c.checkConnectivity());
  yield* c.onConnectivityChanged.map(online);
});

final isOnlineProvider = Provider<bool>((ref) => ref.watch(connectivityProvider).value ?? true);
