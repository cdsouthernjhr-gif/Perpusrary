// Backup & restore end-to-end against real PostgreSQL (see sync_engine_pg_test.dart).
@Tags(['postgres'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/sync/sync_engine.dart';
import 'package:smartlibrary_manager/features/backup/application/backup_service.dart';

import 'helpers/pg_backup_remote.dart';
import 'helpers/pg_sync_remote.dart';

final _env = Platform.environment;
final _skip = _env['SLM_PG_PORT'] == null ? 'SLM_PG_PORT not set (run scripts/sync_integration_test.sh)' : null;

void main() {
  late Connection pg;
  late String libA;
  late String libB;
  final blobs = <String, Uint8List>{};

  Future<Object?> q(String sql, [Map<String, Object?>? p]) async {
    final r = await pg.execute(p == null ? sql : Sql.named(sql), parameters: p);
    return r.isEmpty ? null : r.first.first;
  }

  BackupService service(String user) =>
      BackupService(PgSyncRemote(pg, user), PgBackupRemote(pg, user, blobs));

  setUpAll(() async {
    if (_skip != null) return;
    pg = await Connection.open(
      Endpoint(
        host: _env['SLM_PG_HOST'] ?? '127.0.0.1',
        port: int.parse(_env['SLM_PG_PORT']!),
        database: _env['SLM_PG_DB'] ?? 'slm_test',
        username: _env['SLM_PG_USER'] ?? 'postgres',
        password: _env['SLM_PG_PASSWORD'],
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  setUp(() async {
    if (_skip != null) return;
    blobs.clear();
    await q('select tests.seed()');
    libA = '${await q("select tests.id('lib_a')")}';
    libB = '${await q("select tests.id('lib_b')")}';
  });

  tearDown(() async {
    if (_skip != null) return;
    await q("delete from storage.objects where bucket_id = 'library-backups'");
    await q("delete from public.libraries where id in (select id from tests.ids where key like 'lib_%')");
    await q("delete from auth.users where email like '%@test.local'");
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await pg.close();
  });

  test('admin backup: stored under the library folder with checksum and counts', () async {
    final rec = await service('admin_a').create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A');
    expect(rec.status, 'completed');
    expect(rec.filePath, startsWith('$libA/'));
    expect(rec.recordCounts, {'categories': 1, 'locations': 1, 'books': 1, 'book_copies': 1});
    expect(await q('select status from public.backup_records where id = @id::uuid', {'id': rec.id}), 'completed');
    final bytes = await service('admin_a').download(rec);
    final s = BackupService.validate(bytes, libA);
    expect((s.json['data'] as Map)['books'].toString(), isNot(contains('Asas Fizik')), reason: 'no library B data');
  }, skip: _skip);

  test('restore brings the server back to the backup, after a pre-restore backup; devices pull it', () async {
    final svc = service('admin_a');
    final rec = await svc.create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A');
    final bookA = '${await q("select tests.id('book_a')")}';
    await q("update public.books set title = 'ROSAK', category_id = null where id = @id::uuid", {'id': bookA});
    await q('delete from public.categories where library_id = @l::uuid', {'l': libA});

    final summary = BackupService.validate(await svc.download(rec), libA);
    final res = await svc.restore(summary, libraryCode: 'LIBA', libraryName: 'A', deleteMissing: false);
    expect(res['restored'], isNotNull);
    expect(await q('select title from public.books where id = @id::uuid', {'id': bookA}), 'Hikayat Hang Tuah');
    expect(await q("select count(*) from public.backup_records where library_id = @l::uuid and backup_type = 'pre_restore' "
        "and status = 'completed'", {'l': libA}), 1);

    // A device that synced the deletion gets the category back.
    final db = AppDatabase(NativeDatabase.memory());
    final engine = SyncEngine(db, PgSyncRemote(pg, 'staff_a'));
    await engine.syncLibrary(libA);
    expect((await db.select(db.localCategories).get()).single.name, 'Fiksyen');
    expect((await db.select(db.localBooks).get()).single.title, 'Hikayat Hang Tuah');
    await db.close();
  }, skip: _skip);

  test('cross-library protection: client and server both refuse', () async {
    final recA = await service('admin_a').create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A');
    final bytes = await service('admin_a').download(recA);
    expect(() => BackupService.validate(bytes, libB),
        throwsA(isA<AppFailure>().having((f) => f.code, 'code', 'backup_library')));
    // admin_b cannot even download A's file (Storage RLS)
    await expectLater(service('admin_b').download(recA), throwsA(isA<AppFailure>()));
    // and the server refuses A's backup for library B
    final summaryA = BackupService.validate(bytes, libA);
    await expectLater(
        PgBackupRemote(pg, 'admin_b', blobs).restore(libB, summaryA.json, deleteMissing: false), throwsA(isA<AppFailure>()));
  }, skip: _skip);

  test('staff cannot create or restore backups', () async {
    await expectLater(service('staff_a').create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A'),
        throwsA(isA<AppFailure>()));
    final rec = await service('admin_a').create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A');
    final summary = BackupService.validate(await service('admin_a').download(rec), libA);
    await expectLater(PgBackupRemote(pg, 'staff_a', blobs).restore(libA, summary.json, deleteMissing: false),
        throwsA(isA<AppFailure>().having((f) => f.code, 'code', '42501')));
  }, skip: _skip);

  test('tampered backup file is detected by checksum', () async {
    final svc = service('admin_a');
    final rec = await svc.create(libraryId: libA, libraryCode: 'LIBA', libraryName: 'A');
    final b = blobs[rec.filePath]!;
    blobs[rec.filePath!] = Uint8List.fromList([...b]..[b.length ~/ 2] ^= 0xFF);
    await expectLater(svc.download(rec), throwsA(isA<AppFailure>().having((f) => f.code, 'code', 'checksum')));
  }, skip: _skip);
}
