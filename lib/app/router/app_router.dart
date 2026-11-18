import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/authentication/application/auth_session.dart';
import '../../features/authentication/presentation/login_screen.dart';
import '../../features/authentication/presentation/password_screens.dart';
import '../../features/authentication/presentation/register_screen.dart';
import '../../features/authentication/presentation/splash_screen.dart';
import '../../features/libraries/presentation/library_switcher_placeholder.dart';
import 'routes.dart';

/// Pure redirect logic (unit-tested in test/unit/router_redirect_test.dart).
String? authRedirect({
  required String location,
  required bool signedIn,
  required bool passwordRecovery,
}) {
  if (passwordRecovery) {
    return location == Routes.resetPassword ? null : Routes.resetPassword;
  }
  final isPublic = Routes.public.contains(location);
  if (!signedIn) {
    return isPublic && location != Routes.splash ? null : Routes.login;
  }
  if (isPublic || location == Routes.resetPassword) return Routes.libraries;
  return null;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(authSessionProvider);
  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: session,
    redirect: (context, state) => authRedirect(
      location: state.matchedLocation,
      signedIn: session.isSignedIn,
      passwordRecovery: session.isPasswordRecovery,
    ),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.forgotPassword, builder: (_, _) => const ForgotPasswordScreen()),
      GoRoute(path: Routes.resetPassword, builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(path: Routes.libraries, builder: (_, _) => const LibrarySwitcherPlaceholder()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
