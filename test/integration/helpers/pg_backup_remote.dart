import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres/postgres.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/features/backup/application/backup_service.dart';

/// Test BackupRemote over real PostgreSQL as an authenticated test user.
/// Storage authorisation is real (a row in storage.objects under its RLS
/// policies); only the file bytes live in memory.
class PgBackupRemote implements BackupRemote {
  PgBackupRemote(this._conn, this.userAlias, this.blobs);

  final Connection _conn;
  String userAlias;
  final Map<String, Uint8List> blobs;

  Future<Result> _sql(String sql, [Map<String, Object?>? p]) async {
    try {
      return await _conn.runTx((s) async {
        await s.execute(Sql.named('select tests.claims_for(@a)'), parameters: {'a': userAlias});
        await s.execute('set local role authenticated');
        return s.execute(Sql.named(sql), parameters: p);
      });
    } on ServerException catch (e) {
      throw AppFailure(e.message, code: e.code);
    }
  }

  @override
  Future<List<BackupRecord>> listRecords(String libraryId) async {
    final r = await _sql(
        'select to_jsonb(b) from public.backup_records b where library_id = @l::uuid order by created_at desc',
        {'l': libraryId});
    return [for (final row in r) BackupRecord.fromJson(_map(row.first))];
  }

  Map<String, dynamic> _map(Object? v) => (v is String ? jsonDecode(v) : v)! as Map<String, dynamic>;

  @override
  Future<void> insertRecord(String id, String libraryId, String backupType) => _sql(
      "insert into public.backup_records (id, library_id, backup_type, status) values (@id::uuid, @l::uuid, @t, 'pending')",
      {'id': id, 'l': libraryId, 't': backupType});

  @override
  Future<void> finishRecord(String id,
      {required String status, String? filePath, int? fileSize, String? checksum, Map<String, int>? counts, String? notes}) async {
    final r = await _sql(
        'update public.backup_records set status = @s, file_path = coalesce(@p, file_path), '
        'file_size = coalesce(@z, file_size), checksum = coalesce(@c, checksum), '
        'record_counts = coalesce(@n::jsonb, record_counts), notes = @notes where id = @id::uuid returning id',
        {'s': status, 'p': filePath, 'z': fileSize, 'c': checksum, 'n': counts == null ? null : jsonEncode(counts), 'notes': notes, 'id': id});
    if (r.isEmpty) throw const AppFailure('forbidden', code: '42501');
  }

  @override
  Future<void> upload(String path, Uint8List bytes) async {
    await _sql("insert into storage.objects (bucket_id, name) values ('library-backups', @n)", {'n': path});
    blobs[path] = bytes;
  }

  @override
  Future<Uint8List> download(String path) async {
    final r = await _sql("select 1 from storage.objects where bucket_id = 'library-backups' and name = @n", {'n': path});
    if (r.isEmpty) throw const AppFailure('Fail tidak dijumpai atau tiada akses.', code: '42501');
    return blobs[path]!;
  }

  @override
  Future<Map<String, dynamic>> restore(String libraryId, Map<String, dynamic> backup, {required bool deleteMissing}) async {
    final r = await _sql('select public.restore_library_backup(@l::uuid, @b::jsonb, @d)',
        {'l': libraryId, 'b': jsonEncode(backup), 'd': deleteMissing});
    return _map(r.first.first);
  }
}
