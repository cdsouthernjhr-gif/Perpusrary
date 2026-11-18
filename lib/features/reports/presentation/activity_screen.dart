import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/library_repositories.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';

/// Server activity log of the active library (RLS-filtered), paginated.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _entries = <ActivityEntry>[];
  final _names = <String, String>{};
  String? _entityType;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  static const _entityLabels = {
    null: 'Semua',
    'books': 'Buku',
    'book_copies': 'Naskhah',
    'categories': 'Kategori',
    'locations': 'Lokasi',
    'library_members': 'Ahli',
    'libraries': 'Perpustakaan',
  };
  static const _actionLabels = {
    'create': 'Tambah',
    'update': 'Kemas kini',
    'soft_delete': 'Padam',
    'delete': 'Padam kekal',
    'restore': 'Pulih',
  };

  @override
  void initState() {
    super.initState();
    _loadMore(reset: true);
  }

  Future<void> _loadMore({bool reset = false}) async {
    if (_loading) return;
    final lib = ref.read(activeLibraryProvider);
    if (lib == null) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _entries.clear();
        _hasMore = true;
      }
    });
    try {
      final repo = ref.read(activityRepositoryProvider);
      final page = await repo.libraryFeed(lib.id,
          before: _entries.isEmpty ? null : _entries.last.createdAt, entityType: _entityType);
      final missing = page.map((e) => e.userId).whereType<String>().where((id) => !_names.containsKey(id)).toSet();
      final names = await repo.userNames(missing);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _names.addAll(names);
        _hasMore = page.length == 50;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final fmt = DateFormat('d/M/yyyy HH:mm');
    return Scaffold(
      key: ValueKey('activity.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Log Aktiviti')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final e in _entityLabels.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(e.value),
                      selected: _entityType == e.key,
                      onSelected: (_) {
                        _entityType = e.key;
                        _loadMore(reset: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _error != null && _entries.isEmpty
                ? ErrorView(
                    error: AppFailure.from(_error!).code == 'offline'
                        ? const AppFailure('Log aktiviti disimpan di pelayan. Sambung ke internet untuk melihatnya.')
                        : _error!,
                    onRetry: () => _loadMore(reset: true),
                  )
                : RefreshIndicator(
                    onRefresh: () => _loadMore(reset: true),
                    child: ListView.builder(
                      itemCount: _entries.length + 1,
                      itemBuilder: (context, i) {
                        if (i == _entries.length) {
                          if (_loading) {
                            return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                          }
                          if (_entries.isEmpty) {
                            return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Tiada aktiviti.')));
                          }
                          return _hasMore
                              ? TextButton(onPressed: _loadMore, child: const Text('Muat lagi'))
                              : const SizedBox(height: 24);
                        }
                        final e = _entries[i];
                        final who = e.userId == null ? 'Sistem' : (_names[e.userId] ?? e.userId!.substring(0, 8));
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.history, size: 20),
                          title: Text(
                              '${_actionLabels[e.action] ?? e.action} ${(_entityLabels[e.entityType] ?? e.entityType ?? '').toLowerCase()}'),
                          subtitle: Text([
                            who,
                            if (e.changedFields.isNotEmpty) 'Medan: ${e.changedFields.join(', ')}',
                          ].join(' • ')),
                          trailing: Text(fmt.format(e.createdAt.toLocal()), style: Theme.of(context).textTheme.bodySmall),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
