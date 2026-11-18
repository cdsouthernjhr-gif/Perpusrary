import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/local/dao/catalog_dao.dart';
import '../../../data/local/dao/local_dao.dart';
import '../../../data/local/database/app_database.dart';
import '../../../data/providers.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/models/library_models.dart';
import '../../libraries/application/library_context.dart';

String _lib(Ref ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  return lib.id;
}

typedef BookQuery = ({String text, String? categoryId});

final booksProvider = StreamProvider.autoDispose.family<List<BookListItem>, BookQuery>(
  (ref, q) => ref.watch(catalogDaoProvider).watchBooks(_lib(ref), query: q.text, categoryId: q.categoryId),
);

final bookProvider = StreamProvider.autoDispose.family<LocalBook?, String>(
  (ref, id) => ref.watch(catalogDaoProvider).watchBook(_lib(ref), id),
);

final copiesProvider = StreamProvider.autoDispose.family<List<CopyListItem>, String>(
  (ref, bookId) => ref.watch(catalogDaoProvider).watchCopies(_lib(ref), bookId),
);

typedef CopyQuery = ({String text, String? status});

final allCopiesProvider = StreamProvider.autoDispose.family<List<(CopyListItem, LocalBook)>, CopyQuery>(
  (ref, q) => ref.watch(catalogDaoProvider).watchAllCopies(_lib(ref), query: q.text, status: q.status),
);

final categoriesProvider =
    StreamProvider.autoDispose<List<LocalCategory>>((ref) => ref.watch(catalogDaoProvider).watchCategories(_lib(ref)));

final locationsProvider =
    StreamProvider.autoDispose<List<LocalLocation>>((ref) => ref.watch(catalogDaoProvider).watchLocations(_lib(ref)));

/// Catalogue mutations bound to the ACTIVE library. Role checks here are for
/// immediate feedback only; the server re-checks everything (RLS) on sync.
class CatalogActions {
  CatalogActions(this._dao, this._kv, this.library);

  final CatalogDao _dao;
  final KeyValueDao _kv;
  final LibrarySummary library;

  LibraryPermissions get _p => library.permissions;
  String get _id => library.id;

  void _require(bool allowed) {
    if (!allowed) {
      throw const AppFailure('Anda tidak mempunyai kebenaran untuk tindakan ini.', code: '42501');
    }
  }

  // Categories / locations: editor+
  Future<String> saveCategory(CategoryInput i, {String? id}) {
    _require(_p.canEditCatalog);
    return _dao.saveCategory(_id, i, id: id);
  }

  Future<void> deleteCategory(String id) {
    _require(_p.canEditCatalog);
    return _dao.deleteCategory(_id, id);
  }

  Future<String> saveLocation(LocationInput i, {String? id}) {
    _require(_p.canEditCatalog);
    return _dao.saveLocation(_id, i, id: id);
  }

  Future<void> deleteLocation(String id) {
    _require(_p.canEditCatalog);
    return _dao.deleteLocation(_id, id);
  }

  // Books: register = staff+, edit/delete = editor+
  Future<String> createBook(BookInput i, {List<CopyInput> copies = const [], MovementMeta? meta}) {
    _require(_p.canRegisterBooks);
    return _dao.createBook(_id, i, copies: copies, meta: meta);
  }

  Future<void> updateBook(String id, BookInput i) {
    _require(_p.canEditCatalog);
    return _dao.updateBook(_id, id, i);
  }

  Future<void> deleteBook(String id) {
    _require(_p.canEditCatalog);
    return _dao.deleteBook(_id, id);
  }

  Future<List<DuplicateCandidate>> possibleDuplicates(BookInput i, {String? excludeId}) => _dao.findPossibleDuplicates(
        _id,
        isbn: i.isbn,
        title: i.title,
        author: i.author,
        publisher: i.publisher,
        year: i.publicationYear,
        excludeId: excludeId,
      );

  // Copies: add/update = staff+ (barcode/book change & delete = editor+)
  Future<String> addCopy(String bookId, CopyInput i, {MovementMeta? meta}) {
    _require(_p.canRegisterBooks);
    return _dao.addCopy(_id, bookId, i, meta: meta);
  }

  Future<void> updateCopy(LocalBookCopy current, CopyInput i, {MovementMeta? meta}) {
    _require(_p.canRegisterBooks);
    if (i.barcode.trim() != current.barcode) _require(_p.canEditCatalog);
    return _dao.updateCopy(_id, current.id, i, meta: meta);
  }

  Future<void> deleteCopy(String id) {
    _require(_p.canEditCatalog);
    return _dao.deleteCopy(_id, id);
  }

  Future<(LocalBookCopy, LocalBook?)?> findByBarcode(String barcode) => _dao.findByBarcode(_id, barcode);

  Future<String> generateBarcode() async {
    final deviceId = await _kv.get(LocalKeys.deviceId);
    if (deviceId == null) throw const AppFailure('ID peranti belum tersedia. Sila log masuk semula.');
    return _dao.nextGeneratedBarcode(libraryId: _id, libraryCode: library.code, deviceId: deviceId);
  }

  Future<List<SyncQueueEntry>> unconfirmedOps(String entityId) => _dao.unconfirmedOps(_id, entityId);
}

final catalogActionsProvider = Provider.autoDispose<CatalogActions>((ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  return CatalogActions(ref.watch(catalogDaoProvider), ref.watch(keyValueDaoProvider), lib);
});
