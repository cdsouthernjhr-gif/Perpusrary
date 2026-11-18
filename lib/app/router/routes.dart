abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';

  static const libraries = '/libraries';
  static const libraryNew = '/libraries/new';
  static const invitations = '/invitations';
  static const settings = '/settings';

  // Library-scoped: require an active (verified) library.
  static const dashboard = '/dashboard';
  static const libraryEdit = '/library/edit';
  static const members = '/members';
  static const books = '/books';
  static const bookNew = '/books/new';
  static String book(String id) => '/books/$id';
  static String bookEdit(String id) => '/books/$id/edit';
  static String copyNew(String bookId) => '/books/$bookId/copies/new';
  static String copyEdit(String bookId, String copyId) => '/books/$bookId/copies/$copyId';
  static const copies = '/copies';
  static const barcode = '/barcode';
  static const categories = '/categories';
  static const locations = '/locations';
  static const scanner = '/scanner';
  static const inventory = '/inventory';
  static const inventoryStatus = '/inventory/status';
  static const inventoryRelocate = '/inventory/relocate';
  static const stocktake = '/inventory/stocktake';
  static const movements = '/inventory/movements';
  static const activity = '/activity';
  static String copyMovements(String copyId) => '/inventory/movements?copy=$copyId';

  /// Routes reachable without a session.
  static const public = {splash, login, register, forgotPassword};

  static const libraryScoped = {dashboard, libraryEdit, members, books, copies, barcode, categories, locations, inventory, activity};

  /// Exact scoped routes and their sub-paths (e.g. `/books/{id}/edit`).
  static bool isLibraryScoped(String location) =>
      libraryScoped.any((r) => location == r || location.startsWith('$r/'));
}
