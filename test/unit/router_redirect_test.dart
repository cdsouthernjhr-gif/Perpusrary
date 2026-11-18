import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';

void main() {
  String? r(String loc, {bool signedIn = false, bool recovery = false}) =>
      authRedirect(location: loc, signedIn: signedIn, passwordRecovery: recovery);

  test('signed-out users are sent to login from protected routes and splash', () {
    expect(r(Routes.libraries), Routes.login);
    expect(r(Routes.splash), Routes.login);
    expect(r(Routes.resetPassword), Routes.login);
  });

  test('signed-out users may open public auth routes', () {
    expect(r(Routes.login), isNull);
    expect(r(Routes.register), isNull);
    expect(r(Routes.forgotPassword), isNull);
  });

  test('signed-in users skip auth screens', () {
    expect(r(Routes.login, signedIn: true), Routes.libraries);
    expect(r(Routes.splash, signedIn: true), Routes.libraries);
    expect(r(Routes.libraries, signedIn: true), isNull);
  });


  test('library-scoped routes require an active library', () {
    for (final loc in Routes.libraryScoped) {
      expect(authRedirect(location: loc, signedIn: true, passwordRecovery: false), Routes.libraries);
      expect(authRedirect(location: loc, signedIn: true, passwordRecovery: false, hasActiveLibrary: true), isNull);
    }
    expect(authRedirect(location: Routes.bookEdit('x'), signedIn: true, passwordRecovery: false), Routes.libraries);
    expect(r(Routes.settings, signedIn: true), isNull);
    expect(r(Routes.invitations, signedIn: true), isNull);
  });

  test('password recovery forces the reset screen', () {
    expect(r(Routes.libraries, signedIn: true, recovery: true), Routes.resetPassword);
    expect(r(Routes.resetPassword, signedIn: true, recovery: true), isNull);
  });
}
