/// Library roles, lowest to highest. Super Admin is separate (system level).
enum LibraryRole {
  viewer('viewer', 'Viewer'),
  staff('staff', 'Staf'),
  editor('editor', 'Editor'),
  libraryAdmin('library_admin', 'Pentadbir Perpustakaan');

  const LibraryRole(this.value, this.label);
  final String value;
  final String label;

  static LibraryRole? tryParse(String? v) {
    for (final r in values) {
      if (r.value == v) return r;
    }
    return null;
  }

  bool atLeast(LibraryRole other) => index >= other.index;
}

/// Effective permissions in the active library. UX only — every write is
/// enforced again by RLS on the server.
class LibraryPermissions {
  const LibraryPermissions({required this.role, required this.isSuperAdmin, required this.libraryActive});

  final LibraryRole? role;
  final bool isSuperAdmin;
  final bool libraryActive;

  bool _has(LibraryRole min) => isSuperAdmin || (libraryActive && (role?.atLeast(min) ?? false));

  bool get canRegisterBooks => _has(LibraryRole.staff);
  bool get canEditCatalog => _has(LibraryRole.editor);
  bool get canManageMembers => _has(LibraryRole.libraryAdmin);
  bool get canEditLibrary => isSuperAdmin || (role == LibraryRole.libraryAdmin && libraryActive);
  bool get canChangeLibraryStatus => isSuperAdmin;
}

/// Row of `my_libraries()` / local cache.
class LibrarySummary {
  const LibrarySummary({
    required this.id,
    required this.name,
    required this.code,
    required this.status,
    this.organizationName,
    this.logoPath,
    this.role,
    this.isSuperAdmin = false,
    this.titleCount = 0,
    this.copyCount = 0,
  });

  factory LibrarySummary.fromJson(Map<String, dynamic> j) => LibrarySummary(
        id: j['library_id'] as String,
        name: j['name'] as String,
        code: j['code'] as String,
        status: j['status'] as String,
        organizationName: j['organization_name'] as String?,
        logoPath: j['logo_path'] as String?,
        role: LibraryRole.tryParse(j['role'] as String?),
        isSuperAdmin: (j['is_super_admin'] as bool?) ?? false,
        titleCount: (j['title_count'] as num?)?.toInt() ?? 0,
        copyCount: (j['copy_count'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final String code;
  final String status;
  final String? organizationName;
  final String? logoPath;
  final LibraryRole? role;
  final bool isSuperAdmin;
  final int titleCount;
  final int copyCount;

  bool get isActive => status == 'active';

  /// Whether the user can enter this library at all.
  bool get hasAccess => isSuperAdmin || role != null;

  LibraryPermissions get permissions =>
      LibraryPermissions(role: role, isSuperAdmin: isSuperAdmin, libraryActive: isActive);

  String get roleLabel => role?.label ?? (isSuperAdmin ? 'Super Admin' : '-');

  @override
  bool operator ==(Object other) =>
      other is LibrarySummary &&
      other.id == id &&
      other.name == name &&
      other.code == code &&
      other.status == status &&
      other.role == role &&
      other.isSuperAdmin == isSuperAdmin &&
      other.titleCount == titleCount &&
      other.copyCount == copyCount &&
      other.logoPath == logoPath &&
      other.organizationName == organizationName;

  @override
  int get hashCode => Object.hash(id, name, code, status, role, isSuperAdmin, titleCount, copyCount);
}

/// Full library record (for the edit form).
class LibraryDetails {
  const LibraryDetails({
    this.id,
    required this.name,
    required this.code,
    this.organizationName,
    this.address,
    this.contactPerson,
    this.phone,
    this.email,
    this.establishedOn,
    this.status = 'active',
  });

  factory LibraryDetails.fromJson(Map<String, dynamic> j) => LibraryDetails(
        id: j['id'] as String?,
        name: j['name'] as String,
        code: j['code'] as String,
        organizationName: j['organization_name'] as String?,
        address: j['address'] as String?,
        contactPerson: j['contact_person'] as String?,
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        establishedOn: j['established_on'] == null ? null : DateTime.parse(j['established_on'] as String),
        status: (j['status'] as String?) ?? 'active',
      );

  final String? id;
  final String name;
  final String code;
  final String? organizationName;
  final String? address;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final DateTime? establishedOn;
  final String status;
}

class LibraryMember {
  const LibraryMember({
    required this.memberId,
    required this.userId,
    required this.role,
    required this.status,
    required this.isSelf,
    this.fullName,
    this.email,
    this.joinedAt,
  });

  factory LibraryMember.fromJson(Map<String, dynamic> j) => LibraryMember(
        memberId: j['member_id'] as String,
        userId: j['user_id'] as String,
        role: LibraryRole.tryParse(j['role'] as String?) ?? LibraryRole.viewer,
        status: j['membership_status'] as String,
        isSelf: (j['is_self'] as bool?) ?? false,
        fullName: j['full_name'] as String?,
        email: j['email'] as String?,
        joinedAt: j['joined_at'] == null ? null : DateTime.parse(j['joined_at'] as String),
      );

  final String memberId;
  final String userId;
  final LibraryRole role;
  final String status; // active | suspended | removed
  final bool isSelf;
  final String? fullName;
  final String? email;
  final DateTime? joinedAt;

  bool get isActive => status == 'active';
  String get displayName => (fullName?.trim().isNotEmpty ?? false) ? fullName! : (email ?? userId);
}

class LibraryInvitation {
  const LibraryInvitation({
    required this.id,
    required this.libraryId,
    required this.email,
    required this.role,
    required this.status,
    required this.expiresAt,
    this.libraryName,
  });

  factory LibraryInvitation.fromJson(Map<String, dynamic> j) => LibraryInvitation(
        id: j['id'] as String,
        libraryId: j['library_id'] as String,
        email: j['email'] as String,
        role: LibraryRole.tryParse(j['role'] as String?) ?? LibraryRole.viewer,
        status: j['status'] as String,
        expiresAt: DateTime.parse(j['expires_at'] as String),
        libraryName: j['library_name'] as String?,
      );

  final String id;
  final String libraryId;
  final String email;
  final LibraryRole role;
  final String status;
  final DateTime expiresAt;
  final String? libraryName;

  bool get isExpired => expiresAt.isBefore(DateTime.now());
}
