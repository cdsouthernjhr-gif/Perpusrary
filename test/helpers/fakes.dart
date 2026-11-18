import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/providers.dart';
import 'package:smartlibrary_manager/data/remote/book_metadata_service.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';
import 'package:smartlibrary_manager/features/sync/application/sync_controller.dart';
import 'package:smartlibrary_manager/data/remote/supabase/supabase_providers.dart';
import 'package:smartlibrary_manager/data/repositories/auth_repository.dart';
import 'package:smartlibrary_manager/data/repositories/library_repositories.dart';
import 'package:smartlibrary_manager/shared/models/dashboard_stats.dart';
import 'package:smartlibrary_manager/shared/models/library_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockAuth extends Mock implements AuthRepository {}

class MockDevices extends Mock implements DeviceRepository {}

class MockMembers extends Mock implements MembersRepository {}

/// In-memory fake of the server's view of libraries.
class FakeLibraryRepository implements LibraryRepository {
  FakeLibraryRepository(this.serverLibraries, {this.superAdmin = false});

  List<LibrarySummary> serverLibraries;
  bool superAdmin;
  bool offline = false;
  int fetchCount = 0;

  @override
  Future<List<LibrarySummary>> fetchMyLibraries() async {
    fetchCount++;
    if (offline) throw const AppFailure('Tiada sambungan internet.', code: 'offline');
    return serverLibraries;
  }

  @override
  Future<bool> isSuperAdmin() async {
    if (offline) throw const AppFailure('Tiada sambungan internet.', code: 'offline');
    return superAdmin;
  }

  @override
  Future<String> create(LibraryDetails details, {String? firstAdminEmail}) async => 'new';
  @override
  Future<LibraryDetails> getDetails(String libraryId) async => const LibraryDetails(name: 'x', code: 'X1');
  @override
  Future<void> setStatus(String libraryId, {required bool active}) async {}
  @override
  Future<void> update(String libraryId, LibraryDetails details) async {}
}

class FakeActivityRepository implements ActivityRepository {
  bool offline = false;
  final entries = <ActivityEntry>[];

  @override
  Future<List<ActivityEntry>> historyFor(String libraryId, String entityId) async =>
      offline ? throw const AppFailure('Tiada sambungan internet.', code: 'offline') : const [];

  @override
  Future<List<ActivityEntry>> libraryFeed(String libraryId, {DateTime? before, String? entityType, int limit = 50}) async {
    if (offline) throw const AppFailure('Tiada sambungan internet.', code: 'offline');
    return entries.where((e) => entityType == null || e.entityType == entityType).toList();
  }

  @override
  Future<Map<String, String>> userNames(Set<String> userIds) async => {for (final id in userIds) id: 'Pengguna $id'};
}

/// Scriptable in-memory sync server for widget tests. By default every op is
/// applied and echoed back as a server row (version = base + 1).
class FakeSyncRemote implements SyncRemote {
  bool offline = false;
  PushResult Function(Map<String, dynamic> op)? onPush;
  final pushed = <Map<String, dynamic>>[];

  static Map<String, dynamic> serverRowFor(String libraryId, Map<String, dynamic> op, {int? version}) => {
        ...(op['payload'] as Map<String, dynamic>),
        'id': op['entity_id'],
        'library_id': libraryId,
        'version': version ?? ((op['base_version'] as int?) ?? 0) + 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'deleted_at': op['operation_type'] == 'delete' ? DateTime.now().toUtc().toIso8601String() : null,
      };

  @override
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations) async {
    if (offline) throw const SyncTransportException('offline');
    pushed.addAll(operations);
    return [
      for (final op in operations)
        onPush?.call(op) ??
            PushResult(
              operationId: op['operation_id'] as String,
              status: 'applied',
              serverRow: op['operation_type'] == 'delete' ? null : serverRowFor(libraryId, op),
            ),
    ];
  }

  @override
  Future<PullPage> pull(String libraryId, String entityType,
      {String? since, String? afterXid, String? afterId, int limit = 500}) async {
    if (offline) throw const SyncTransportException('offline');
    return const PullPage(rows: [], hasMore: false, snapshotXmin: '1');
  }
}

class FakeDashboardRepository implements DashboardRepository {
  final requested = <String>[];

  @override
  Future<DashboardStats> fetch(String libraryId) async {
    requested.add(libraryId);
    return DashboardStats(
      titleCount: libraryId == 'lib-a' ? 11 : 22,
      copyCount: libraryId == 'lib-a' ? 110 : 220,
      categoryCount: 1,
      locationCount: 1,
    );
  }
}

LibrarySummary libA({LibraryRole role = LibraryRole.libraryAdmin}) => LibrarySummary(
    id: 'lib-a', name: 'Perpustakaan Sekolah A', code: 'LIBA', status: 'active', role: role, titleCount: 11);
LibrarySummary libB({LibraryRole role = LibraryRole.staff}) => LibrarySummary(
    id: 'lib-b', name: 'Perpustakaan Daerah B', code: 'LIBB', status: 'active', role: role, titleCount: 22);

User fakeUser(String id) => User(
      id: id,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.now().toIso8601String(),
      email: '$id@test.local',
    );

class TestHarness {
  TestHarness(
      {List<LibrarySummary>? server, String userId = 'user-1', this.online = true, bool superAdmin = false, this.autoSync = false})
      : db = AppDatabase(NativeDatabase.memory()),
        auth = MockAuth(),
        devices = MockDevices(),
        members = MockMembers(),
        libraries = FakeLibraryRepository(server ?? [libA(), libB()], superAdmin: superAdmin),
        dashboard = FakeDashboardRepository(),
        activity = FakeActivityRepository(),
        sync = FakeSyncRemote() {
    setUser(userId);
    when(() => auth.authEvents).thenAnswer((_) => const Stream.empty());
    when(() => devices.register(
        deviceId: any(named: 'deviceId'),
        deviceName: any(named: 'deviceName'),
        appVersion: any(named: 'appVersion'))).thenAnswer((_) async {});
    when(() => members.myPendingInvitations()).thenAnswer((_) async => const []);
  }

  final AppDatabase db;
  final MockAuth auth;
  final MockDevices devices;
  final MockMembers members;
  final FakeLibraryRepository libraries;
  final FakeDashboardRepository dashboard;
  final FakeActivityRepository activity;
  final FakeSyncRemote sync;
  final bool online;
  final bool autoSync;

  void setUser(String? id) => when(() => auth.currentUser).thenReturn(id == null ? null : fakeUser(id));

  List<Override> get overrides => [
        appDatabaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWithValue(auth),
        deviceRepositoryProvider.overrideWithValue(devices),
        membersRepositoryProvider.overrideWithValue(members),
        libraryRepositoryProvider.overrideWithValue(libraries),
        dashboardRepositoryProvider.overrideWithValue(dashboard),
        activityRepositoryProvider.overrideWithValue(activity),
        syncRemoteProvider.overrideWithValue(sync),
        autoSyncEnabledProvider.overrideWithValue(autoSync),
        connectivityProvider.overrideWith((ref) => Stream.value(online)),
        isOnlineProvider.overrideWithValue(online),
        // Never hit the real internet in tests: metadata lookups "not found".
        bookMetadataServiceProvider
            .overrideWithValue(BookMetadataService(client: MockClient((_) async => http.Response('{}', 404)))),
      ];

  ProviderContainer container() => ProviderContainer(overrides: overrides);
}
