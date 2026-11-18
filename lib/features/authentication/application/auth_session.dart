import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/remote/supabase/supabase_providers.dart';
import '../../../data/repositories/auth_repository.dart';

/// Tracks sign-in state for the router (refreshListenable).
class AuthSession extends ChangeNotifier {
  AuthSession(this._repo) {
    _signedIn = _repo.currentUser != null;
    _sub = _repo.authEvents.listen(_onEvent);
  }

  final AuthRepository _repo;
  late final StreamSubscription<AuthChangeEvent> _sub;
  bool _signedIn = false;
  bool _passwordRecovery = false;

  bool get isSignedIn => _signedIn;

  /// True after the user opened a password-reset link; the router then
  /// forces the "set new password" screen.
  bool get isPasswordRecovery => _passwordRecovery;

  void completePasswordRecovery() {
    _passwordRecovery = false;
    notifyListeners();
  }

  void _onEvent(AuthChangeEvent event) {
    switch (event) {
      case AuthChangeEvent.passwordRecovery:
        _passwordRecovery = true;
        _signedIn = true;
      case AuthChangeEvent.signedOut:
        _signedIn = false;
        _passwordRecovery = false;
      default:
        _signedIn = _repo.currentUser != null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final authSessionProvider = Provider<AuthSession>((ref) {
  final session = AuthSession(ref.watch(authRepositoryProvider));
  ref.onDispose(session.dispose);
  return session;
});
