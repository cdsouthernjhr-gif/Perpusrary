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
  TestHarness({List<LibrarySummary>? server, String userId = 'user-1', this.online = true, bool superAdmin = false})
      : db = AppDatabase(NativeDatabase.memory()),
        auth = MockAuth(),
        devices = MockDevices(),
        members = MockMembers(),
        libraries = FakeLibraryRepository(server ?? [libA(), libB()], superAdmin: superAdmin),
        dashboard = FakeDashboardRepository() {
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
  final bool online;

  void setUser(String? id) => when(() => auth.currentUser).thenReturn(id == null ? null : fakeUser(id));

  List<Override> get overrides => [
        appDatabaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWithValue(auth),
        deviceRepositoryProvider.overrideWithValue(devices),
        membersRepositoryProvider.overrideWithValue(members),
        libraryRepositoryProvider.overrideWithValue(libraries),
        dashboardRepositoryProvider.overrideWithValue(dashboard),
        connectivityProvider.overrideWith((ref) => Stream.value(online)),
        isOnlineProvider.overrideWithValue(online),
        // Never hit the real internet in tests: metadata lookups "not found".
        bookMetadataServiceProvider
            .overrideWithValue(BookMetadataService(client: MockClient((_) async => http.Response('{}', 404)))),
      ];

  ProviderContainer container() => ProviderContainer(overrides: overrides);
}
