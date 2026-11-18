import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/app_drawer.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../libraries/application/library_context.dart';
import '../application/catalog_providers.dart';
import 'catalog_widgets.dart';

class BooksScreen extends ConsumerStatefulWidget {
  const BooksScreen({super.key});

  @override
  ConsumerState<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends ConsumerState<BooksScreen> {
  final _search = TextEditingController();
  String _text = '';
  String? _categoryId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(activeLibraryProvider);
    if (lib == null) return const SizedBox.shrink();
    final perms = ref.watch(activePermissionsProvider);
    final books = ref.watch(booksProvider((text: _text, categoryId: _categoryId)));
    final categories = ref.watch(categoriesProvider).value ?? const [];

    return Scaffold(
      key: ValueKey('books.${lib.id}'),
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: Text('Buku – ${lib.code}'),
        actions: [
          IconButton(
            tooltip: 'Cari melalui barcode',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => context.push(Routes.barcode),
          ),
        ],
      ),
      floatingActionButton: perms.canRegisterBooks
          ? FloatingActionButton.extended(
              key: const Key('books.add'),
              onPressed: () => context.push(Routes.bookNew),
              icon: const Icon(Icons.add),
              label: const Text('Daftar buku'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const Key('books.search'),
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Cari tajuk, pengarang atau ISBN',
                suffixIcon: _text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _search.clear();
                          _text = '';
                        }),
                      ),
              ),
              onChanged: (v) => setState(() => _text = v),
            ),
          ),
          if (categories.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: const Text('Semua'),
                      selected: _categoryId == null,
                      onSelected: (_) => setState(() => _categoryId = null),
                    ),
                  ),
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(c.name),
                        selected: _categoryId == c.id,
                        onSelected: (s) => setState(() => _categoryId = s ? c.id : null),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: books.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(error: e),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _text.isEmpty && _categoryId == null
                              ? 'Belum ada buku dalam peranti ini untuk ${lib.name}.'
                              : 'Tiada buku sepadan dengan carian.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => _BookTile(item: list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.item});
  final BookListItem item;

  @override
  Widget build(BuildContext context) {
    final b = item.book;
    return ListTile(
      key: Key('book.${b.id}'),
      leading: BookCover(url: b.coverImagePath, size: 48),
      title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (b.author != null) b.author!,
        if (b.isbn != null) 'ISBN ${b.isbn}',
        if (item.categoryName != null) item.categoryName!,
      ].join(' • ')),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${item.copyCount} naskhah', style: Theme.of(context).textTheme.labelMedium),
          SyncStateIcon(state: b.syncState),
        ],
      ),
      onTap: () => context.push(Routes.book(b.id)),
    );
  }
}
