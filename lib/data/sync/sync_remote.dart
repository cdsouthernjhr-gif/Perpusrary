import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of one pushed operation, as returned by `sync_push`.
class PushResult {
  const PushResult({
    required this.operationId,
    required this.status,
    this.errorCode,
    this.errorMessage,
    this.serverRow,
    this.duplicate = false,
  });

  factory PushResult.fromJson(Map<String, dynamic> j) => PushResult(
        operationId: '${j['operation_id']}',
        status: j['status'] as String,
        errorCode: j['error_code'] as String?,
        errorMessage: j['error_message'] as String?,
        serverRow: j['server_row'] as Map<String, dynamic>?,
        duplicate: (j['duplicate'] as bool?) ?? false,
      );

  final String operationId;
  final String status; // applied | conflict | rejected | failed
  final String? errorCode;
  final String? errorMessage;
  final Map<String, dynamic>? serverRow;
  final bool duplicate;
}

class PullPage {
  const PullPage({
    required this.rows,
    required this.hasMore,
    required this.snapshotXmin,
    this.lastXid,
    this.lastId,
  });

  factory PullPage.fromJson(Map<String, dynamic> j) => PullPage(
        rows: ((j['rows'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        hasMore: (j['has_more'] as bool?) ?? false,
        snapshotXmin: '${j['snapshot_xmin']}',
        lastXid: j['last_xid'] as String?,
        lastId: j['last_id'] as String?,
      );

  final List<Map<String, dynamic>> rows;
  final bool hasMore;
  final String snapshotXmin;
  final String? lastXid;
  final String? lastId;
}

/// Network/transient failure: safe to retry later with the SAME operation ids.
class SyncTransportException implements Exception {
  const SyncTransportException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'SyncTransportException: $message';
}

/// The server refused access to the library (membership removed, library
/// deactivated, session expired). Syncing this library must stop.
class SyncAccessDenied implements Exception {
  const SyncAccessDenied(this.message);
  final String message;
  @override
  String toString() => 'SyncAccessDenied: $message';
}

abstract interface class SyncRemote {
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations);

  Future<PullPage> pull(
    String libraryId,
    String entityType, {
    String? since,
    String? afterXid,
    String? afterId,
    int limit = 500,
  });
}

/// Maps transport-level errors to sync exceptions (shared by implementations).
Never rethrowAsSyncError(Object e) {
  if (e is SyncTransportException || e is SyncAccessDenied) throw e;
  if (e is SocketException || e is TimeoutException || e is http.ClientException || e is HandshakeException) {
    throw SyncTransportException('Tiada sambungan ke pelayan.', e);
  }
  if (e is AuthException) throw SyncAccessDenied('Sesi tamat. Sila log masuk semula.');
  if (e is PostgrestException) {
    final code = e.code ?? '';
    if (code == '42501' || code == '28000' || code.startsWith('PGRST3')) {
      throw SyncAccessDenied(e.message);
    }
    // 5xx / gateway / statement timeout → transient
    if (code.isEmpty || code.startsWith('5') || code == '57014' || code.startsWith('08')) {
      throw SyncTransportException(e.message, e);
    }
  }
  throw SyncTransportException('Ralat pelayan: $e', e);
}

class SupabaseSyncRemote implements SyncRemote {
  SupabaseSyncRemote(this._db, {this.timeout = const Duration(seconds: 30)});

  final SupabaseClient _db;
  final Duration timeout;

  @override
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations) async {
    try {
      final res = await _db.rpc<Map<String, dynamic>>('sync_push', params: {
        'p_library_id': libraryId,
        'p_device_id': deviceId,
        'p_operations': operations,
      }).timeout(timeout);
      return ((res['results'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PushResult.fromJson).toList();
    } catch (e) {
      rethrowAsSyncError(e);
    }
  }

  @override
  Future<PullPage> pull(String libraryId, String entityType,
      {String? since, String? afterXid, String? afterId, int limit = 500}) async {
    try {
      final res = await _db.rpc<Map<String, dynamic>>('sync_pull', params: {
        'p_library_id': libraryId,
        'p_entity_type': entityType,
        'p_since': since,
        'p_after_xid': afterXid,
        'p_after_id': afterId,
        'p_limit': limit,
      }).timeout(timeout);
      return PullPage.fromJson(res);
    } catch (e) {
      rethrowAsSyncError(e);
    }
  }
}
