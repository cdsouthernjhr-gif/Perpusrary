import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Server-side import record (public.import_jobs). Best effort: an import
/// done offline is still applied locally and synced; only its job record is
/// skipped.
abstract interface class ImportJobRepository {
  Future<String?> start(String libraryId, String fileName, String duplicateMode, int totalRows);
  Future<void> finish(String id, {required String status, required int ok, required int failed, List<Map<String, Object?>> errors});
}

class SupabaseImportJobRepository implements ImportJobRepository {
  SupabaseImportJobRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<String?> start(String libraryId, String fileName, String duplicateMode, int totalRows) async {
    final id = const Uuid().v4();
    try {
      await _db.from('import_jobs').insert({
        'id': id,
        'library_id': libraryId,
        'file_name': fileName.length > 255 ? fileName.substring(0, 255) : fileName,
        'duplicate_mode': duplicateMode,
        'status': 'importing',
        'total_rows': totalRows,
      });
      return id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> finish(String id,
      {required String status, required int ok, required int failed, List<Map<String, Object?>> errors = const []}) async {
    try {
      await _db.from('import_jobs').update({
        'status': status,
        'successful_rows': ok,
        'failed_rows': failed,
        'error_summary': errors.take(200).toList(),
        'completed_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);
    } catch (_) {}
  }
}
