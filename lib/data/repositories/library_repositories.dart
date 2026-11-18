import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';
import '../../shared/models/dashboard_stats.dart';
import '../../shared/models/library_models.dart';

/// Libraries visible to the signed-in user + library administration.
abstract interface class LibraryRepository {
  /// Authoritative list from the server (`my_libraries()`).
  Future<List<LibrarySummary>> fetchMyLibraries();

  /// Server-side check (public.system_admins, own row only).
  Future<bool> isSuperAdmin();
  Future<LibraryDetails> getDetails(String libraryId);
  Future<String> create(LibraryDetails details, {String? firstAdminEmail});
  Future<void> update(String libraryId, LibraryDetails details);
  Future<void> setStatus(String libraryId, {required bool active});
}

abstract interface class MembersRepository {
  Future<List<LibraryMember>> listMembers(String libraryId);
  Future<List<LibraryInvitation>> listInvitations(String libraryId);
  Future<void> invite(String libraryId, {required String email, required LibraryRole role});
  Future<void> revokeInvitation(String invitationId);
  Future<void> changeRole(String memberId, LibraryRole role);
  Future<void> setMembershipStatus(String memberId, String status);
  Future<List<LibraryInvitation>> myPendingInvitations();
  Future<String> acceptInvitation(String invitationId);
}

abstract interface class DashboardRepository {
  Future<DashboardStats> fetch(String libraryId);
}

class UserProfile {
  const UserProfile({required this.id, this.fullName, this.phone, this.email});
  final String id;
  final String? fullName;
  final String? phone;
  final String? email;
}

abstract interface class ProfileRepository {
  Future<UserProfile> getMine();
  Future<void> updateMine({required String fullName, String? phone});
}

class ActivityEntry {
  const ActivityEntry({required this.action, required this.createdAt, this.userId, this.details = const {}});
  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
        action: j['action'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
        userId: j['user_id'] as String?,
        details: (j['details'] as Map<String, dynamic>?) ?? const {},
      );
  final String action;
  final DateTime createdAt;
  final String? userId;
  final Map<String, dynamic> details;

  /// Changed field names for an update entry.
  List<String> get changedFields =>
      ((details['changes'] as Map<String, dynamic>?) ?? const {}).keys.toList();
}

/// Server-side change history (activity_logs, RLS-filtered).
abstract interface class ActivityRepository {
  Future<List<ActivityEntry>> historyFor(String libraryId, String entityId);
}

class SupabaseActivityRepository implements ActivityRepository {
  SupabaseActivityRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<List<ActivityEntry>> historyFor(String libraryId, String entityId) => _guard(() async {
        final rows = await _db
            .from('activity_logs')
            .select('action, created_at, user_id, details')
            .eq('library_id', libraryId)
            .eq('entity_id', entityId)
            .order('created_at', ascending: false)
            .limit(50);
        return rows.map(ActivityEntry.fromJson).toList();
      });
}

abstract interface class DeviceRepository {
  Future<void> register({required String deviceId, required String deviceName, required String appVersion});
}

// ---------------------------------------------------------------------------
// Supabase implementations
// ---------------------------------------------------------------------------

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } catch (e) {
    throw AppFailure.from(e);
  }
}

/// PostgREST UPDATEs silently affect 0 rows when RLS hides the row; turn
/// that into an explicit permission failure.
void _requireRows(List<dynamic> rows) {
  if (rows.isEmpty) {
    throw const AppFailure('Anda tidak mempunyai kebenaran untuk tindakan ini.', code: '42501');
  }
}

class SupabaseLibraryRepository implements LibraryRepository {
  SupabaseLibraryRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<List<LibrarySummary>> fetchMyLibraries() => _guard(() async {
        final rows = await _db.rpc<List<dynamic>>('my_libraries');
        return rows.cast<Map<String, dynamic>>().map(LibrarySummary.fromJson).toList();
      });

  @override
  Future<bool> isSuperAdmin() => _guard(() async {
        final uid = _db.auth.currentUser?.id;
        if (uid == null) return false;
        final row = await _db.from('system_admins').select('user_id').eq('user_id', uid).maybeSingle();
        return row != null;
      });

  @override
  Future<LibraryDetails> getDetails(String libraryId) => _guard(() async {
        final row = await _db.from('libraries').select().eq('id', libraryId).single();
        return LibraryDetails.fromJson(row);
      });

  @override
  Future<String> create(LibraryDetails d, {String? firstAdminEmail}) => _guard(() async {
        final id = await _db.rpc<String>('create_library', params: {
          'p_name': d.name,
          'p_code': d.code,
          'p_organization_name': d.organizationName,
          'p_address': d.address,
          'p_contact_person': d.contactPerson,
          'p_phone': d.phone,
          'p_email': d.email,
          'p_established_on': d.establishedOn?.toIso8601String().substring(0, 10),
          'p_admin_email': firstAdminEmail,
        });
        return id;
      });

  @override
  Future<void> update(String libraryId, LibraryDetails d) => _guard(() async {
        final rows = await _db
            .from('libraries')
            .update({
              'name': d.name.trim(),
              // Unchanged code passes; a changed code is only accepted from a
              // Super Admin (server trigger tg_libraries_guard).
              'code': d.code.trim().toUpperCase(),
              'organization_name': _blankToNull(d.organizationName),
              'address': _blankToNull(d.address),
              'contact_person': _blankToNull(d.contactPerson),
              'phone': _blankToNull(d.phone),
              'email': _blankToNull(d.email),
              'established_on': d.establishedOn?.toIso8601String().substring(0, 10),
            })
            .eq('id', libraryId)
            .select('id');
        _requireRows(rows);
      });

  @override
  Future<void> setStatus(String libraryId, {required bool active}) => _guard(() async {
        final rows = await _db
            .from('libraries')
            .update({'status': active ? 'active' : 'inactive'})
            .eq('id', libraryId)
            .select('id');
        _requireRows(rows);
      });
}

class SupabaseMembersRepository implements MembersRepository {
  SupabaseMembersRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<List<LibraryMember>> listMembers(String libraryId) => _guard(() async {
        final rows = await _db.rpc<List<dynamic>>('library_member_list', params: {'p_library_id': libraryId});
        return rows.cast<Map<String, dynamic>>().map(LibraryMember.fromJson).toList();
      });

  @override
  Future<List<LibraryInvitation>> listInvitations(String libraryId) => _guard(() async {
        final rows = await _db
            .from('library_invitations')
            .select()
            .eq('library_id', libraryId)
            .order('created_at', ascending: false)
            .limit(200);
        return rows.map(LibraryInvitation.fromJson).toList();
      });

  @override
  Future<void> invite(String libraryId, {required String email, required LibraryRole role}) => _guard(() async {
        // library_id comes from the active (server-verified) library; RLS
        // rejects it anyway if the caller is not that library's admin.
        await _db.from('library_invitations').insert({
          'library_id': libraryId,
          'email': email.trim().toLowerCase(),
          'role': role.value,
        });
      });

  @override
  Future<void> revokeInvitation(String invitationId) => _guard(() async {
        final rows = await _db
            .from('library_invitations')
            .update({'status': 'revoked'})
            .eq('id', invitationId)
            .eq('status', 'pending')
            .select('id');
        _requireRows(rows);
      });

  @override
  Future<void> changeRole(String memberId, LibraryRole role) => _guard(() async {
        final rows =
            await _db.from('library_members').update({'role': role.value}).eq('id', memberId).select('id');
        _requireRows(rows);
      });

  @override
  Future<void> setMembershipStatus(String memberId, String status) => _guard(() async {
        final rows = await _db
            .from('library_members')
            .update({'membership_status': status})
            .eq('id', memberId)
            .select('id');
        _requireRows(rows);
      });

  @override
  Future<List<LibraryInvitation>> myPendingInvitations() => _guard(() async {
        final email = _db.auth.currentUser?.email;
        if (email == null) return const [];
        final rows = await _db
            .from('library_invitations')
            .select()
            .eq('status', 'pending')
            .ilike('email', email)
            .order('created_at', ascending: false);
        return rows.map(LibraryInvitation.fromJson).where((i) => !i.isExpired).toList();
      });

  @override
  Future<String> acceptInvitation(String invitationId) =>
      _guard(() => _db.rpc<String>('accept_invitation', params: {'p_invitation_id': invitationId}));
}

class SupabaseDashboardRepository implements DashboardRepository {
  SupabaseDashboardRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<DashboardStats> fetch(String libraryId) => _guard(() async {
        final json = await _db.rpc<Map<String, dynamic>>('library_dashboard', params: {'p_library_id': libraryId});
        return DashboardStats.fromJson(json);
      });
}

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._db);
  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw const AppFailure('Sesi telah tamat. Sila log masuk semula.');
    return id;
  }

  @override
  Future<UserProfile> getMine() => _guard(() async {
        final r = await _db.from('user_profiles').select().eq('id', _uid).single();
        return UserProfile(
          id: r['id'] as String,
          fullName: r['full_name'] as String?,
          phone: r['phone'] as String?,
          email: r['email'] as String?,
        );
      });

  @override
  Future<void> updateMine({required String fullName, String? phone}) => _guard(() async {
        final rows = await _db
            .from('user_profiles')
            .update({'full_name': fullName.trim(), 'phone': _blankToNull(phone)})
            .eq('id', _uid)
            .select('id');
        _requireRows(rows);
      });
}

class SupabaseDeviceRepository implements DeviceRepository {
  SupabaseDeviceRepository(this._db);
  final SupabaseClient _db;

  @override
  Future<void> register({required String deviceId, required String deviceName, required String appVersion}) =>
      _guard(() async {
        final uid = _db.auth.currentUser?.id;
        if (uid == null) return;
        await _db.from('device_registry').upsert({
          'id': deviceId,
          'user_id': uid,
          'device_name': deviceName,
          'platform': 'android',
          'app_version': appVersion,
          'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        });
      });
}

String? _blankToNull(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
