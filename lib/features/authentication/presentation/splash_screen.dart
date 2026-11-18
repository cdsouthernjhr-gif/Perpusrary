import 'package:material_ui/material_ui.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_library_rounded, size: 80, color: scheme.onPrimary),
            const SizedBox(height: 16),
            Text('SmartLibrary Manager',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: scheme.onPrimary)),
            const SizedBox(height: 24),
            CircularProgressIndicator(color: scheme.onPrimary),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of the app when build-time configuration is invalid
/// (e.g. missing URL, or a forbidden service_role key).
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Konfigurasi tidak sah')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Aplikasi tidak dapat dimulakan kerana:'),
            const SizedBox(height: 12),
            for (final p in problems) ListTile(leading: const Icon(Icons.error_outline), title: Text(p)),
            const SizedBox(height: 12),
            const Text('Rujuk docs/installation.md untuk menetapkan --dart-define-from-file.'),
          ],
        ),
      ),
    );
  }
}
