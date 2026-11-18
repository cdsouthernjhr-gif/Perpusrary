import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/sync/backoff.dart';
import 'package:smartlibrary_manager/data/sync/server_row_mapper.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('retry delay grows exponentially, is capped and jittered', () {
    final r = Random(1);
    final d = [for (var i = 1; i <= 12; i++) retryDelay(i, random: r).inMilliseconds / 1000];
    expect(d[0], inInclusiveRange(4, 6));
    expect(d[1], inInclusiveRange(8, 12));
    expect(d[3], inInclusiveRange(32, 48));
    expect(d.last, inInclusiveRange(720, 1080), reason: 'capped at 15 min ±20%');
  });

  test('error classification: network → retry, RLS/auth → access denied', () {
    expect(() => rethrowAsSyncError(const SocketException('x')), throwsA(isA<SyncTransportException>()));
    expect(() => rethrowAsSyncError(const PostgrestException(message: 'no', code: '42501')),
        throwsA(isA<SyncAccessDenied>()));
    expect(() => rethrowAsSyncError(const PostgrestException(message: 'jwt', code: 'PGRST301')),
        throwsA(isA<SyncAccessDenied>()));
    expect(() => rethrowAsSyncError(const AuthException('expired')), throwsA(isA<SyncAccessDenied>()));
    expect(() => rethrowAsSyncError(const PostgrestException(message: 'timeout', code: '57014')),
        throwsA(isA<SyncTransportException>()));
  });

  test('server copy row maps to a local companion (cents, dates, version)', () {
    final c = ServerRowMapper.copy({
      'id': 'c1',
      'library_id': 'L',
      'book_id': 'b1',
      'barcode': 'X1',
      'condition': 'good',
      'status': 'available',
      'acquisition_cost': 25.9,
      'acquisition_date': '2026-03-07',
      'version': 3,
      'created_at': '2026-11-18T01:02:03.456+00:00',
      'updated_at': '2026-11-18T01:02:03.456+00:00',
      'deleted_at': null,
    });
    expect(c.acquisitionCostCents.value, 2590);
    expect(c.acquisitionDate.value, DateTime(2026, 3, 7));
    expect(c.serverVersion.value, 3);
    expect(c.syncState.value, 'synced');
  });

  test('push / pull JSON parsing', () {
    final p = PushResult.fromJson({
      'operation_id': 'op',
      'status': 'conflict',
      'error_code': 'version_mismatch',
      'server_row': {'version': 2},
      'duplicate': true
    });
    expect(p.duplicate, isTrue);
    expect(p.serverRow!['version'], 2);
    final page = PullPage.fromJson({'rows': [], 'has_more': false, 'snapshot_xmin': 123});
    expect(page.snapshotXmin, '123');
  });
}
