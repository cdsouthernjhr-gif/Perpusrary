import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';

/// Test-only SyncRemote that talks to a real PostgreSQL with the SmartLibrary
/// migrations applied, calling the same RPCs PostgREST would call, as the
/// `authenticated` role with JWT claims of a test user (RLS fully applies).
class PgSyncRemote implements SyncRemote {
  PgSyncRemote(this._conn, this.userAlias);

  final Connection _conn;
  String userAlias; // tests.users alias (e.g. 'staff_a')

  Future<T> _asUser<T>(Future<T> Function(TxSession s) body) => _conn.runTx((s) async {
        await s.execute(Sql.named('select tests.claims_for(@a)'), parameters: {'a': userAlias});
        await s.execute('set local role authenticated');
        return body(s);
      });

  Object? _json(Object? v) => v is String ? jsonDecode(v) : v;

  Never _map(Object e) {
    if (e is ServerException && (e.code == '42501' || e.code == '28000')) throw SyncAccessDenied(e.message);
    if (e is SocketException || e is PgException) throw SyncTransportException('$e', e);
    throw e;
  }

  @override
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations) async {
    try {
      final res = await _asUser((s) async {
        final r = await s.execute(
          Sql.named('select public.sync_push(@lib::uuid, @dev::uuid, @ops::jsonb)'),
          parameters: {'lib': libraryId, 'dev': deviceId, 'ops': jsonEncode(operations)},
        );
        return _json(r.first.first)! as Map<String, dynamic>;
      });
      return (res['results'] as List).cast<Map<String, dynamic>>().map(PushResult.fromJson).toList();
    } catch (e) {
      _map(e);
    }
  }

  @override
  Future<PullPage> pull(String libraryId, String entityType,
      {String? since, String? afterXid, String? afterId, int limit = 500}) async {
    try {
      final res = await _asUser((s) async {
        final r = await s.execute(
          Sql.named('select public.sync_pull(@lib::uuid, @e, @since, @ax, @aid::uuid, @lim)'),
          parameters: {'lib': libraryId, 'e': entityType, 'since': since, 'ax': afterXid, 'aid': afterId, 'lim': limit},
        );
        return _json(r.first.first)! as Map<String, dynamic>;
      });
      return PullPage.fromJson(res);
    } catch (e) {
      _map(e);
    }
  }
}

/// Simulates an unreliable network around a real remote.
class FlakyRemote implements SyncRemote {
  FlakyRemote(this.inner);
  final SyncRemote inner;

  /// Apply the push on the server, then drop the response.
  bool loseNextPushResponse = false;

  /// Fail before reaching the server.
  bool offline = false;

  /// Runs while a push is "in flight" (before it reaches the server).
  Future<void> Function()? duringPush;

  @override
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations) async {
    if (offline) throw const SyncTransportException('offline');
    final hook = duringPush;
    duringPush = null;
    if (hook != null) await hook();
    final r = await inner.push(libraryId, deviceId, operations);
    if (loseNextPushResponse) {
      loseNextPushResponse = false;
      throw const SyncTransportException('connection reset after server commit');
    }
    return r;
  }

  @override
  Future<PullPage> pull(String libraryId, String entityType,
      {String? since, String? afterXid, String? afterId, int limit = 500}) {
    if (offline) throw const SyncTransportException('offline');
    return inner.pull(libraryId, entityType, since: since, afterXid: afterXid, afterId: afterId, limit: limit);
  }
}
