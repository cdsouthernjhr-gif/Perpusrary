import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/errors/app_failure.dart';
import '../../features/sync/application/sync_status.dart';

/// Online / offline / syncing / synced / failed / conflict chip.
class SyncIndicatorChip extends ConsumerWidget {
  const SyncIndicatorChip({super.key, required this.libraryId, this.compact = false});

  final String libraryId;
  final bool compact;

  static ({IconData icon, String label, Color Function(ColorScheme) color}) describe(SyncIndicator s) =>
      switch (s) {
        SyncIndicator.offline => (icon: Icons.cloud_off, label: 'Luar talian', color: (c) => c.outline),
        SyncIndicator.syncing => (icon: Icons.sync, label: 'Sedang sync', color: (c) => c.primary),
        SyncIndicator.conflict => (icon: Icons.warning_amber, label: 'Konflik data', color: (c) => c.tertiary),
        SyncIndicator.failed => (icon: Icons.sync_problem, label: 'Sync gagal', color: (c) => c.error),
        SyncIndicator.pending => (icon: Icons.cloud_upload_outlined, label: 'Menunggu sync', color: (c) => c.secondary),
        SyncIndicator.synced => (icon: Icons.cloud_done_outlined, label: 'Sync selesai', color: (c) => Colors.green.shade700),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncIndicatorProvider(libraryId));
    final d = describe(status);
    final color = d.color(Theme.of(context).colorScheme);
    if (compact) {
      return Tooltip(message: d.label, child: Icon(d.icon, color: color, semanticLabel: d.label));
    }
    return Chip(
      key: Key('sync.${status.name}'),
      avatar: Icon(d.icon, size: 18, color: color),
      label: Text(d.label),
      side: BorderSide(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Library logo placeholder (initials). Logo upload: later phase.
class LibraryAvatar extends StatelessWidget {
  const LibraryAvatar({super.key, required this.name, this.radius = 24});

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final initials = words.length >= 2
        ? '${words[words.length - 2][0]}${words.last[0]}'
        : (words.isEmpty ? '?' : words.first.substring(0, words.first.length.clamp(0, 2)));
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      child: Text(initials.toUpperCase(), style: TextStyle(fontSize: radius * 0.7, fontWeight: FontWeight.w600)),
    );
  }
}

/// Uniform async error view with retry.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(AppFailure.from(error).message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Cuba lagi')),
            ],
          ],
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? scheme.error : null,
    ));
}

/// Runs [action], showing a friendly error snackbar on failure.
/// Returns true on success.
Future<bool> runWithFeedback(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, AppFailure.from(e).message, error: true);
    return false;
  }
}
