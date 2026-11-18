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

  /// Routes reachable without a session.
  static const public = {splash, login, register, forgotPassword};

  static const libraryScoped = {dashboard, libraryEdit, members};
}
