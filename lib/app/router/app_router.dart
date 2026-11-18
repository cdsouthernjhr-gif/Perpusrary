import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/authentication/application/auth_session.dart';
import '../../features/authentication/presentation/login_screen.dart';
import '../../features/authentication/presentation/password_screens.dart';
import '../../features/authentication/presentation/register_screen.dart';
import '../../features/authentication/presentation/splash_screen.dart';
import '../../features/barcode/presentation/barcode_lookup_screen.dart';
import '../../features/barcode/presentation/scanner_screen.dart';
import '../../features/book_copies/presentation/copies_screen.dart';
import '../../features/book_copies/presentation/copy_form_screen.dart';
import '../../features/books/presentation/book_detail_screen.dart';
import '../../features/books/presentation/book_form_screen.dart';
import '../../features/books/presentation/books_screen.dart';
import '../../features/categories/presentation/categories_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/locations/presentation/locations_screen.dart';
import '../../features/libraries/application/library_context.dart';
import '../../features/libraries/presentation/library_form_screen.dart';
import '../../features/libraries/presentation/library_switcher_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/users/presentation/members_screen.dart';
import '../../features/users/presentation/my_invitations_screen.dart';
import 'routes.dart';

/// Pure redirect logic (unit-tested in test/unit/router_redirect_test.dart).
String? authRedirect({
  required String location,
  required bool signedIn,
  required bool passwordRecovery,
  bool hasActiveLibrary = false,
}) {
  if (passwordRecovery) {
    return location == Routes.resetPassword ? null : Routes.resetPassword;
  }
  final isPublic = Routes.public.contains(location);
  if (!signedIn) {
    return isPublic && location != Routes.splash ? null : Routes.login;
  }
  if (isPublic || location == Routes.resetPassword) return Routes.libraries;
  if (Routes.isLibraryScoped(location) && !hasActiveLibrary) return Routes.libraries;
  return null;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(authSessionProvider);
  final libraryChanged = ValueNotifier<int>(0);
  ref.listen(activeLibraryProvider, (_, _) => libraryChanged.value++);
  ref.onDispose(libraryChanged.dispose);

  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: Listenable.merge([session, libraryChanged]),
    redirect: (context, state) => authRedirect(
      location: state.matchedLocation,
      signedIn: session.isSignedIn,
      passwordRecovery: session.isPasswordRecovery,
      hasActiveLibrary: ref.read(activeLibraryProvider) != null,
    ),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.forgotPassword, builder: (_, _) => const ForgotPasswordScreen()),
      GoRoute(path: Routes.resetPassword, builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(path: Routes.libraries, builder: (_, _) => const LibrarySwitcherScreen()),
      GoRoute(path: Routes.libraryNew, builder: (_, _) => const LibraryFormScreen()),
      GoRoute(path: Routes.invitations, builder: (_, _) => const MyInvitationsScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(path: Routes.dashboard, builder: (_, _) => const DashboardScreen()),
      GoRoute(path: Routes.members, builder: (_, _) => const MembersScreen()),
      GoRoute(path: Routes.books, builder: (_, _) => const BooksScreen()),
      GoRoute(path: Routes.bookNew, builder: (_, _) => const BookFormScreen()),
      GoRoute(path: '/books/:id', builder: (_, s) => BookDetailScreen(bookId: s.pathParameters['id']!)),
      GoRoute(path: '/books/:id/edit', builder: (_, s) => BookFormScreen(bookId: s.pathParameters['id']!)),
      GoRoute(path: '/books/:id/copies/new', builder: (_, s) => CopyFormScreen(bookId: s.pathParameters['id']!)),
      GoRoute(
        path: '/books/:id/copies/:copyId',
        builder: (_, s) => CopyFormScreen(bookId: s.pathParameters['id']!, copyId: s.pathParameters['copyId']),
      ),
      GoRoute(path: Routes.copies, builder: (_, _) => const CopiesScreen()),
      GoRoute(path: Routes.barcode, builder: (_, _) => const BarcodeLookupScreen()),
      GoRoute(path: Routes.categories, builder: (_, _) => const CategoriesScreen()),
      GoRoute(path: Routes.locations, builder: (_, _) => const LocationsScreen()),
      GoRoute(
        path: Routes.scanner,
        builder: (_, s) => ScannerScreen(mode: s.extra as ScanMode? ?? ScanMode.copyBarcode),
      ),
      GoRoute(
        path: Routes.libraryEdit,
        builder: (_, _) => LibraryFormScreen(libraryId: ref.read(activeLibraryProvider)?.id),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
