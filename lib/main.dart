import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/security/secure_session_storage.dart';
import 'data/local/database/app_database.dart';
import 'data/providers.dart';
import 'data/remote/supabase/supabase_providers.dart';
import 'features/authentication/presentation/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();
  final problems = config.validate();
  if (problems.isNotEmpty) {
    runApp(ConfigErrorApp(problems: problems));
    return;
  }

  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabaseAnonKey,
    authOptions: FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      localStorage: SecureSessionStorage(),
      pkceAsyncStorage: SecurePkceStorage(),
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        supabaseClientProvider.overrideWithValue(Supabase.instance.client),
        appDatabaseProvider.overrideWithValue(AppDatabase.open()),
      ],
      child: const SmartLibraryApp(),
    ),
  );
}
