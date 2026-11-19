import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../application/catalog_providers.dart';
import '../application/cover_store.dart';

/// Cover thumbnail: an https URL from an ISBN catalogue, or a photo taken
/// on a device (`storage:` ref — shown from the local copy, downloaded from
/// the private bucket when missing). Otherwise — or offline — a placeholder.
class BookCover extends ConsumerWidget {
  const BookCover({super.key, required this.url, this.size = 56});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size * 1.4,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
      child: Icon(Icons.menu_book, color: scheme.outline, size: size * 0.5),
    );
    final u = url;
    Widget clip(Widget child) => ClipRRect(borderRadius: BorderRadius.circular(4), child: child);
    if (u != null && CoverRef.objectPath(u) != null) {
      final file = ref.watch(coverFileProvider(u)).value;
      if (file == null) return placeholder;
      return clip(Image.file(
        file,
        width: size,
        height: size * 1.4,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => placeholder,
      ));
    }
    if (u == null || !u.startsWith('https://')) return placeholder;
    return clip(Image.network(
      u,
      width: size,
      height: size * 1.4,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
    ));
  }
}

/// Small per-record sync state marker.
class SyncStateIcon extends StatelessWidget {
  const SyncStateIcon({super.key, required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String tip) = switch (state) {
      'pending' => (Icons.cloud_upload_outlined, scheme.secondary, 'Menunggu sync'),
      'conflict' => (Icons.warning_amber, scheme.tertiary, 'Konflik data'),
      'rejected' => (Icons.error_outline, scheme.error, 'Ditolak pelayan'),
      _ => (Icons.cloud_done_outlined, Colors.green.shade700, 'Disegerakkan'),
    };
    return Tooltip(message: tip, child: Icon(icon, size: 18, color: color, semanticLabel: tip));
  }
}

class CopyStatusChip extends StatelessWidget {
  const CopyStatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = CopyStatus.parse(status);
    final scheme = Theme.of(context).colorScheme;
    final color = switch (s) {
      CopyStatus.available => Colors.green.shade700,
      CopyStatus.inProcessing => scheme.secondary,
      CopyStatus.damaged || CopyStatus.lost => scheme.error,
      CopyStatus.inactive => scheme.outline,
    };
    return Chip(
      label: Text(s.label, style: TextStyle(color: color)),
      side: BorderSide(color: color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}

/// Shown when a barcode is already in use (spec §8: refuse, warn, offer to
/// open the existing record).
Future<void> showDuplicateBarcodeDialog(BuildContext context, WidgetRef ref, AppFailure failure, String barcode,
    {VoidCallback? onGenerateNew}) async {
  final existing = await ref.read(catalogActionsProvider).findByBarcode(barcode);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.block),
      title: const Text('Barcode sudah digunakan'),
      content: Text(
        '${failure.message}\n\n'
        '${existing?.$2 != null ? 'Rekod sedia ada: "${existing!.$2!.title}"' : ''}'
        '${existing?.$1.deletedAt != null ? ' (naskhah telah dipadam — barcode kekal terpelihara)' : ''}',
      ),
      actions: [
        if (existing?.$2 != null)
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              context.push(Routes.book(existing!.$2!.id));
            },
            child: const Text('Lihat rekod sedia ada'),
          ),
        if (onGenerateNew != null)
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              onGenerateNew();
            },
            child: const Text('Jana barcode baharu'),
          ),
        FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Tutup')),
      ],
    ),
  );
}

/// Generic save handler that routes duplicate-barcode errors to the dialog.
Future<bool> saveWithBarcodeHandling(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  required String barcode,
  String? success,
  VoidCallback? onGenerateNew,
}) async {
  try {
    await action();
    if (context.mounted && success != null) showSnack(context, success);
    return true;
  } catch (e) {
    final f = AppFailure.from(e);
    if (!context.mounted) return false;
    if (f.code == 'duplicate_barcode') {
      await showDuplicateBarcodeDialog(context, ref, f, barcode, onGenerateNew: onGenerateNew);
    } else {
      showSnack(context, f.message, error: true);
    }
    return false;
  }
}
