import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/remote/supabase/supabase_providers.dart';
import 'package:smartlibrary_manager/data/repositories/auth_repository.dart';
import 'package:smartlibrary_manager/features/authentication/presentation/login_screen.dart';

class _MockAuth extends Mock implements AuthRepository {}

Widget _wrap(AuthRepository repo) => ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: LoginScreen()),
    );

void main() {
  late _MockAuth repo;

  setUp(() {
    repo = _MockAuth();
    when(() => repo.authEvents).thenAnswer((_) => const Stream.empty());
  });

  testWidgets('shows validation errors and does not call signIn on empty form', (tester) async {
    await tester.pumpWidget(_wrap(repo));
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pump();
    expect(find.text('E-mel diperlukan.'), findsOneWidget);
    expect(find.text('Kata laluan diperlukan.'), findsOneWidget);
    verifyNever(() => repo.signIn(email: any(named: 'email'), password: any(named: 'password')));
  });

  testWidgets('calls signIn and shows a friendly error on failure', (tester) async {
    when(() => repo.signIn(email: any(named: 'email'), password: any(named: 'password')))
        .thenThrow(const AppFailure('E-mel atau kata laluan tidak betul.'));
    await tester.pumpWidget(_wrap(repo));
    await tester.enterText(find.byKey(const Key('login.email')), 'staf@sekolah.my');
    await tester.enterText(find.byKey(const Key('login.password')), 'salah123');
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();
    verify(() => repo.signIn(email: 'staf@sekolah.my', password: 'salah123')).called(1);
    expect(find.text('E-mel atau kata laluan tidak betul.'), findsOneWidget);
  });
}
