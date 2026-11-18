abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const libraries = '/libraries';

  /// Routes reachable without a session.
  static const public = {splash, login, register, forgotPassword};
}
