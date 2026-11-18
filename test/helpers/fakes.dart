import 'dart:typed_data';
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
import 'package:smartlibrary_manager/core/files/file_io.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';
import 'package:smartlibrary_manager/features/backup/application/backup_providers.dart';
import 'package:smartlibrary_manager/features/backup/application/backup_service.dart';
import 'package:smartlibrary_manager/features/excel_import/application/import_jobs.dart';
import 'package:smartlibrary_manager/features/excel_import/application/import_providers.dart';
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

class FakeFileIo implements FileIo {
  (String, Uint8List)? nextPick;
  final saved = <String, Uint8List>{};

  @override
  Future<(String, Uint8List)?> pick({required List<String> extensions}) async => nextPick;

  @override
  Future<bool> save(String fileName, Uint8List bytes, {required String extension}) async {
    saved[fileName] = bytes;
    return true;
  }
}

class FakeImportJobs implements ImportJobRepository {
  final events = <String>[];
  @override
  Future<String?> start(String libraryId, String fileName, String duplicateMode, int totalRows) async {
    events.add('start:$fileName:$totalRows');
    return 'job-1';
  }

  @override
  Future<void> finish(String id,
      {required String status, required int ok, required int failed, List<Map<String, Object?>> errors = const []}) async {
    events.add('finish:$status:$ok:$failed');
  }
}

class FakeBackupRemote implements BackupRemote {
  final records = <BackupRecord>[];
  final blobs = <String, Uint8List>{};
  final restores = <(String, bool)>[];

  @override
  Future<List<BackupRecord>> listRecords(String libraryId) async =>
      records.where((r) => r.libraryId == libraryId).toList().reversed.toList();

  @override
  Future<void> insertRecord(String id, String libraryId, String backupType) async => records.add(BackupRecord(
      id: id, libraryId: libraryId, backupType: backupType, status: 'pending', createdAt: DateTime.now()));

  @override
  Future<void> finishRecord(String id,
      {required String status, String? filePath, int? fileSize, String? checksum, Map<String, int>? counts, String? notes}) async {
    final i = records.indexWhere((r) => r.id == id);
    final r = records[i];
    records[i] = BackupRecord(
        id: id,
        libraryId: r.libraryId,
        backupType: r.backupType,
        status: status,
        createdAt: r.createdAt,
        filePath: filePath,
        fileSize: fileSize,
        checksum: checksum,
        recordCounts: counts ?? const {});
  }

  @override
  Future<void> upload(String path, Uint8List bytes) async => blobs[path] = bytes;

  @override
  Future<Uint8List> download(String path) async => blobs[path]!;

  @override
  Future<Map<String, dynamic>> restore(String libraryId, Map<String, dynamic> backup, {required bool deleteMissing}) async {
    restores.add((libraryId, deleteMissing));
    return {'restored': {}};
  }
}

class FakeProfileRepository implements ProfileRepository {
  @override
  Future<UserProfile> getMine() async =>
      const UserProfile(id: 'user-1', fullName: 'Pengguna Ujian', phone: '012-3456789', email: 'user-1@test.local');
  @override
  Future<void> updateMine({required String fullName, String? phone}) async {}
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
      {List<LibrarySummary>? server,
      String userId = 'user-1',
      this.online = true,
      bool superAdmin = false,
      this.autoSync = false,
      AppDatabase? database})
      : db = database ?? AppDatabase(NativeDatabase.memory()),
        auth = MockAuth(),
        devices = MockDevices(),
        members = MockMembers(),
        libraries = FakeLibraryRepository(server ?? [libA(), libB()], superAdmin: superAdmin),
        dashboard = FakeDashboardRepository(),
        activity = FakeActivityRepository(),
        sync = FakeSyncRemote(),
        files = FakeFileIo(),
        backups = FakeBackupRemote(),
        importJobs = FakeImportJobs() {
    setUser(userId);
    when(() => auth.authEvents).thenAnswer((_) => const Stream.empty());
    when(() => devices.register(
        deviceId: any(named: 'deviceId'),
        deviceName: any(named: 'deviceName'),
        appVersion: any(named: 'appVersion'))).thenAnswer((_) async {});
    when(() => members.myPendingInvitations()).thenAnswer((_) async => const []);
    when(() => members.listMembers(any())).thenAnswer((_) async => [
          const LibraryMember(
              memberId: 'm1', userId: 'user-1', role: LibraryRole.libraryAdmin, status: 'active', isSelf: true,
              fullName: 'Pentadbir Perpustakaan Dengan Nama Yang Panjang', email: 'pentadbir.panjang@sekolah.edu.my'),
        ]);
    when(() => members.listInvitations(any())).thenAnswer((_) async => [
          LibraryInvitation(id: 'i1', libraryId: 'lib-a', email: 'jemputan.panjang@sekolah.edu.my',
              role: LibraryRole.staff, status: 'pending', expiresAt: DateTime(2030)),
        ]);
  }

  final AppDatabase db;
  final MockAuth auth;
  final MockDevices devices;
  final MockMembers members;
  final FakeLibraryRepository libraries;
  final FakeDashboardRepository dashboard;
  final FakeActivityRepository activity;
  final FakeSyncRemote sync;
  final FakeFileIo files;
  final FakeBackupRemote backups;
  final FakeImportJobs importJobs;
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
        fileIoProvider.overrideWithValue(files),
        backupRemoteProvider.overrideWithValue(backups),
        importJobRepositoryProvider.overrideWithValue(importJobs),
        profileRepositoryProvider.overrideWithValue(FakeProfileRepository()),
        connectivityProvider.overrideWith((ref) => Stream.value(online)),
        isOnlineProvider.overrideWithValue(online),
        // Never hit the real internet in tests: metadata lookups "not found".
        bookMetadataServiceProvider
            .overrideWithValue(BookMetadataService(client: MockClient((_) async => http.Response('{}', 404)))),
      ];

  ProviderContainer container() => ProviderContainer(overrides: overrides);
}
