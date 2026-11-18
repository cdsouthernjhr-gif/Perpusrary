import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../books/application/catalog_providers.dart';
import '../../books/presentation/catalog_widgets.dart';
import '../../libraries/application/library_context.dart';

/// All physical copies of the active library.
class CopiesScreen extends ConsumerStatefulWidget {
  const CopiesScreen({super.key});

  @override
  ConsumerState<CopiesScreen> createState() => _CopiesScreenState();
}

class _CopiesScreenState extends ConsumerState<CopiesScreen> {
  String _text = '';
  String? _status;

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final copies = ref.watch(allCopiesProvider((text: _text, status: _status)));
    return Scaffold(
      key: ValueKey('copies.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('Pengurusan Naskhah')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Barcode, no. perolehan atau tajuk'),
              onChanged: (v) => setState(() => _text = v),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final s in [null, ...CopyStatus.values])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(s?.label ?? 'Semua'),
                      selected: _status == s?.value,
                      onSelected: (_) => setState(() => _status = s?.value),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: copies.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(error: e),
              data: (list) => list.isEmpty
                  ? const Center(child: Text('Tiada naskhah.'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final (item, book) = list[i];
                        return ListTile(
                          leading: const Icon(Icons.qr_code_2),
                          title: Text('${item.copy.barcode} — ${book.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(item.location == null ? 'Lokasi belum ditetapkan' : locationLabel(item.location!)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            CopyStatusChip(status: item.copy.status),
                            SyncStateIcon(state: item.copy.syncState),
                          ]),
                          onTap: () => context.push(Routes.book(book.id)),
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
