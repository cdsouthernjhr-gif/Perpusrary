import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Uint8List;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/sync/sync_remote.dart';

class BackupRecord {
  const BackupRecord({
    required this.id,
    required this.libraryId,
    required this.backupType,
    required this.status,
    required this.createdAt,
    this.filePath,
    this.fileSize,
    this.checksum,
    this.recordCounts = const {},
  });

  factory BackupRecord.fromJson(Map<String, dynamic> j) => BackupRecord(
        id: j['id'] as String,
        libraryId: j['library_id'] as String,
        backupType: j['backup_type'] as String,
        status: j['status'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
        filePath: j['file_path'] as String?,
        fileSize: (j['file_size'] as num?)?.toInt(),
        checksum: j['checksum'] as String?,
        recordCounts: ((j['record_counts'] as Map<String, dynamic>?) ?? const {})
            .map((k, v) => MapEntry(k, (v as num).toInt())),
      );

  final String id;
  final String libraryId;
  final String backupType; // manual | automatic | pre_restore
  final String status; // pending | completed | failed
  final DateTime createdAt;
  final String? filePath;
  final int? fileSize;
  final String? checksum;
  final Map<String, int> recordCounts;
}

/// Server side of backups (Storage + backup_records + restore RPC).
abstract interface class BackupRemote {
  Future<List<BackupRecord>> listRecords(String libraryId);
  Future<void> insertRecord(String id, String libraryId, String backupType);
  Future<void> finishRecord(String id,
      {required String status, String? filePath, int? fileSize, String? checksum, Map<String, int>? counts, String? notes});
  Future<void> upload(String path, Uint8List bytes);
  Future<Uint8List> download(String path);
  Future<Map<String, dynamic>> restore(String libraryId, Map<String, dynamic> backup, {required bool deleteMissing});
}

class BackupSummary {
  const BackupSummary({required this.json, required this.libraryId, required this.libraryCode, required this.createdAt,
      required this.counts});
  final Map<String, dynamic> json;
  final String libraryId;
  final String? libraryCode;
  final DateTime? createdAt;
  final Map<String, int> counts;
}

/// Backups are built from the SERVER's data (sync_pull, RLS-filtered) so they
/// contain exactly what the server holds for this library — never another
/// library's rows, never unconfirmed local edits.
class BackupService {
  BackupService(this._sync, this._remote, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final SyncRemote _sync;
  final BackupRemote _remote;
  final DateTime Function() _clock;

  static const format = 'smartlibrary-backup';
  static const version = 1;
  static const entities = ['categories', 'locations', 'books', 'book_copies'];

  static String storagePath(String libraryId, String backupId, DateTime at) =>
      '$libraryId/${at.year}/$backupId.json.gz';

  Future<Map<String, dynamic>> buildJson({
    required String libraryId,
    required String libraryCode,
    required String libraryName,
    String? createdBy,
  }) async {
    final data = <String, List<Map<String, dynamic>>>{};
    for (final e in entities) {
      final rows = <Map<String, dynamic>>[];
      String? afterXid;
      String? afterId;
      while (true) {
        final p = await _sync.pull(libraryId, e, afterXid: afterXid, afterId: afterId, limit: 1000);
        rows.addAll(p.rows.where((r) => r['library_id'] == libraryId));
        if (!p.hasMore) break;
        afterXid = p.lastXid;
        afterId = p.lastId;
      }
      data[e] = rows;
    }
    return {
      'format': format,
      'version': version,
      'created_at': _clock().toUtc().toIso8601String(),
      'created_by': createdBy,
      'library': {'id': libraryId, 'code': libraryCode, 'name': libraryName},
      'counts': {for (final e in entities) e: data[e]!.length},
      'data': data,
    };
  }

  static Uint8List encode(Map<String, dynamic> json) =>
      Uint8List.fromList(GZipEncoder().encode(utf8.encode(jsonEncode(json))));

  static String checksumOf(Uint8List bytes) => sha256.convert(bytes).toString();

  /// Creates a backup on the server: record (pending) → upload → record (completed).
  Future<BackupRecord> create({
    required String libraryId,
    required String libraryCode,
    required String libraryName,
    String backupType = 'manual',
    String? createdBy,
  }) async {
    final id = const Uuid().v4();
    final now = _clock();
    final path = storagePath(libraryId, id, now);
    await _remote.insertRecord(id, libraryId, backupType);
    try {
      final json = await buildJson(
          libraryId: libraryId, libraryCode: libraryCode, libraryName: libraryName, createdBy: createdBy);
      final bytes = encode(json);
      final sum = checksumOf(bytes);
      await _remote.upload(path, bytes);
      final counts = (json['counts'] as Map<String, int>);
      await _remote.finishRecord(id,
          status: 'completed', filePath: path, fileSize: bytes.length, checksum: sum, counts: counts);
      return BackupRecord(
        id: id,
        libraryId: libraryId,
        backupType: backupType,
        status: 'completed',
        createdAt: now,
        filePath: path,
        fileSize: bytes.length,
        checksum: sum,
        recordCounts: counts,
      );
    } catch (e) {
      await _remote.finishRecord(id, status: 'failed', notes: '$e'.substring(0, '$e'.length.clamp(0, 900)));
      rethrow;
    }
  }

  /// Downloads a stored backup and verifies its checksum.
  Future<Uint8List> download(BackupRecord r) async {
    if (r.filePath == null) throw const AppFailure('Fail backup tidak tersedia.');
    final bytes = await _remote.download(r.filePath!);
    if (r.checksum != null && checksumOf(bytes) != r.checksum) {
      throw const AppFailure('Fail backup rosak (checksum tidak sepadan).', code: 'checksum');
    }
    return bytes;
  }

  /// Validates a backup file (gzip or plain JSON) for [expectedLibraryId].
  /// Mirrors the server checks so the user sees problems before confirming.
  static BackupSummary validate(Uint8List bytes, String expectedLibraryId) {
    Map<String, dynamic> json;
    try {
      final raw = (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) ? GZipDecoder().decodeBytes(bytes) : bytes;
      json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (_) {
      throw const AppFailure('Fail ini bukan backup SmartLibrary yang sah.', code: 'backup_format');
    }
    if (json['format'] != format || json['version'] != version) {
      throw const AppFailure('Format atau versi backup tidak disokong.', code: 'backup_format');
    }
    final lib = json['library'] as Map<String, dynamic>?;
    if (lib?['id'] != expectedLibraryId) {
      throw AppFailure(
          'Backup ini milik perpustakaan lain (${lib?['code'] ?? '?'}). Restore hanya dibenarkan ke perpustakaan asal.',
          code: 'backup_library');
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) throw const AppFailure('Backup tiada data.', code: 'backup_format');
    final ids = <String, Set<String>>{};
    for (final e in entities) {
      final rows = data[e];
      if (rows is! List) throw AppFailure('Bahagian "$e" dalam backup tidak sah.', code: 'backup_format');
      for (final r in rows.cast<Map<String, dynamic>>()) {
        if (r['library_id'] != expectedLibraryId) {
          throw const AppFailure('Backup mengandungi rekod perpustakaan lain.', code: 'backup_library');
        }
      }
      ids[e] = rows.cast<Map<String, dynamic>>().map((r) => r['id'] as String).toSet();
    }
    final barcodes = <String>{};
    for (final c in (data['book_copies'] as List).cast<Map<String, dynamic>>()) {
      if (!ids['books']!.contains(c['book_id'])) {
        throw const AppFailure('Hubungan rekod rosak: naskhah merujuk buku yang tiada dalam backup.', code: 'backup_relations');
      }
      final loc = c['location_id'];
      if (loc != null && !ids['locations']!.contains(loc)) {
        throw const AppFailure('Hubungan rekod rosak: naskhah merujuk lokasi yang tiada dalam backup.',
            code: 'backup_relations');
      }
      if (!barcodes.add(c['barcode'] as String)) {
        throw AppFailure('Barcode "${c['barcode']}" berulang dalam backup.', code: 'backup_relations');
      }
    }
    for (final b in (data['books'] as List).cast<Map<String, dynamic>>()) {
      final cat = b['category_id'];
      if (cat != null && !ids['categories']!.contains(cat)) {
        throw const AppFailure('Hubungan rekod rosak: buku merujuk kategori yang tiada dalam backup.',
            code: 'backup_relations');
      }
    }
    return BackupSummary(
      json: json,
      libraryId: expectedLibraryId,
      libraryCode: lib?['code'] as String?,
      createdAt: DateTime.tryParse('${json['created_at']}'),
      counts: {for (final e in entities) e: (data[e] as List).length},
    );
  }

  /// Restores [summary] after taking an automatic "pre_restore" backup of
  /// the current state (so a restore can itself be undone).
  Future<Map<String, dynamic>> restore(BackupSummary summary,
      {required String libraryCode, required String libraryName, required bool deleteMissing}) async {
    await create(
        libraryId: summary.libraryId, libraryCode: libraryCode, libraryName: libraryName, backupType: 'pre_restore');
    return _remote.restore(summary.libraryId, summary.json, deleteMissing: deleteMissing);
  }
}

class SupabaseBackupRemote implements BackupRemote {
  SupabaseBackupRemote(this._db);
  final SupabaseClient _db;
  static const bucket = 'library-backups';

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  @override
  Future<List<BackupRecord>> listRecords(String libraryId) => _guard(() async {
        final rows = await _db
            .from('backup_records')
            .select()
            .eq('library_id', libraryId)
            .order('created_at', ascending: false)
            .limit(100);
        return rows.map(BackupRecord.fromJson).toList();
      });

  @override
  Future<void> insertRecord(String id, String libraryId, String backupType) => _guard(() =>
      _db.from('backup_records').insert({'id': id, 'library_id': libraryId, 'backup_type': backupType, 'status': 'pending'}));

  @override
  Future<void> finishRecord(String id,
          {required String status, String? filePath, int? fileSize, String? checksum, Map<String, int>? counts, String? notes}) =>
      _guard(() => _db.from('backup_records').update({
            'status': status,
            'file_path': ?filePath,
            'file_size': ?fileSize,
            'checksum': ?checksum,
            'record_counts': ?counts,
            'notes': ?notes,
          }).eq('id', id));

  @override
  Future<void> upload(String path, Uint8List bytes) => _guard(() => _db.storage
      .from(bucket)
      .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'application/gzip', upsert: false)));

  @override
  Future<Uint8List> download(String path) => _guard(() => _db.storage.from(bucket).download(path));

  @override
  Future<Map<String, dynamic>> restore(String libraryId, Map<String, dynamic> backup, {required bool deleteMissing}) =>
      _guard(() => _db.rpc<Map<String, dynamic>>('restore_library_backup',
          params: {'p_library_id': libraryId, 'p_backup': backup, 'p_delete_missing': deleteMissing}));
}
