/// Result of `library_dashboard()` (or a local fallback when offline).
class DashboardStats {
  const DashboardStats({
    required this.titleCount,
    required this.copyCount,
    required this.categoryCount,
    required this.locationCount,
    this.copiesByStatus = const {},
    this.titlesRegisteredToday = 0,
    this.copiesRegisteredToday = 0,
    this.activeMemberCount = 0,
    this.usersSyncingNow = 0,
    this.failedSyncCount = 0,
    this.devices = const [],
    this.recentActivity = const [],
    this.byCategory = const [],
    this.generatedAt,
    this.isLocalFallback = false,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> j) {
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    List<Map<String, dynamic>> list(String k) => ((j[k] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>();
    return DashboardStats(
      titleCount: i('title_count'),
      copyCount: i('copy_count'),
      categoryCount: i('category_count'),
      locationCount: i('location_count'),
      copiesByStatus: ((j['copies_by_status'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, (v as num).toInt())),
      titlesRegisteredToday: i('titles_registered_today'),
      copiesRegisteredToday: i('copies_registered_today'),
      activeMemberCount: i('active_member_count'),
      usersSyncingNow: i('users_syncing_now'),
      failedSyncCount: i('failed_sync_count'),
      devices: list('devices').map(DeviceSyncInfo.fromJson).toList(),
      recentActivity: list('recent_activity').map(ActivityItem.fromJson).toList(),
      byCategory: list('by_category').map(CategorySummary.fromJson).toList(),
      generatedAt: j['generated_at'] == null ? null : DateTime.parse(j['generated_at'] as String),
    );
  }

  final int titleCount;
  final int copyCount;
  final int categoryCount;
  final int locationCount;
  final Map<String, int> copiesByStatus;
  final int titlesRegisteredToday;
  final int copiesRegisteredToday;
  final int activeMemberCount;
  final int usersSyncingNow;
  final int failedSyncCount;
  final List<DeviceSyncInfo> devices;
  final List<ActivityItem> recentActivity;
  final List<CategorySummary> byCategory;
  final DateTime? generatedAt;

  /// True when computed from the device's local copy (offline).
  final bool isLocalFallback;
}

class DeviceSyncInfo {
  const DeviceSyncInfo({required this.deviceId, required this.userId, this.lastSyncAt});
  factory DeviceSyncInfo.fromJson(Map<String, dynamic> j) => DeviceSyncInfo(
        deviceId: j['device_id'] as String,
        userId: j['user_id'] as String,
        lastSyncAt: j['last_sync_at'] == null ? null : DateTime.parse(j['last_sync_at'] as String),
      );
  final String deviceId;
  final String userId;
  final DateTime? lastSyncAt;
}

class ActivityItem {
  const ActivityItem({required this.action, required this.entityType, required this.createdAt, this.userId});
  factory ActivityItem.fromJson(Map<String, dynamic> j) => ActivityItem(
        action: j['action'] as String,
        entityType: j['entity_type'] as String,
        userId: j['user_id'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
  final String action;
  final String entityType;
  final String? userId;
  final DateTime createdAt;

  String get label {
    const actions = {
      'create': 'Tambah',
      'update': 'Kemas kini',
      'soft_delete': 'Padam',
      'delete': 'Padam kekal',
      'restore': 'Pulih',
      'export_excel': 'Eksport Excel',
    };
    const entities = {
      'books': 'buku',
      'book_copies': 'naskhah',
      'categories': 'kategori',
      'locations': 'lokasi',
      'library_members': 'ahli',
      'libraries': 'perpustakaan',
      'app_event': '',
    };
    return '${actions[action] ?? action} ${entities[entityType] ?? entityType}'.trim();
  }
}

class CategorySummary {
  const CategorySummary({required this.name, required this.titleCount, required this.copyCount});
  factory CategorySummary.fromJson(Map<String, dynamic> j) => CategorySummary(
        name: j['category_name'] as String,
        titleCount: (j['title_count'] as num).toInt(),
        copyCount: (j['copy_count'] as num).toInt(),
      );
  final String name;
  final int titleCount;
  final int copyCount;
}
