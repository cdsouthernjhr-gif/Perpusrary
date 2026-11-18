import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';

/// Authentication boundary. UI and controllers depend on this interface so
/// they can be tested without a Supabase backend.
abstract interface class AuthRepository {
  User? get currentUser;
  Stream<AuthChangeEvent> get authEvents;

  Future<void> signIn({required String email, required String password});
  Future<void> signUp({required String email, required String password, required String fullName});
  Future<void> sendPasswordReset(String email);
  Future<void> updatePassword(String newPassword);
  Future<void> signOut();
}

/// Deep link registered in AndroidManifest.xml for e-mail confirmation and
/// password-reset links. Must also be added to Supabase Auth "Redirect URLs".
const authRedirectUrl = 'my.smartlibrary.manager://auth-callback';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  User? get currentUser => _auth.currentUser;

  @override
  Stream<AuthChangeEvent> get authEvents => _auth.onAuthStateChange.map((s) => s.event);

  @override
  Future<void> signIn({required String email, required String password}) =>
      _guard(() => _auth.signInWithPassword(email: email.trim(), password: password));

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
  }) =>
      _guard(() => _auth.signUp(
            email: email.trim(),
            password: password,
            // Display name only. Authorization NEVER reads user metadata.
            data: {'full_name': fullName.trim()},
            emailRedirectTo: authRedirectUrl,
          ));

  @override
  Future<void> sendPasswordReset(String email) =>
      _guard(() => _auth.resetPasswordForEmail(email.trim(), redirectTo: authRedirectUrl));

  @override
  Future<void> updatePassword(String newPassword) =>
      _guard(() => _auth.updateUser(UserAttributes(password: newPassword)));

  @override
  Future<void> signOut() => _guard(() => _auth.signOut());

  Future<void> _guard(Future<Object?> Function() action) async {
    try {
      await action();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
