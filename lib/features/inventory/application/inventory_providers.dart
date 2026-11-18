import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../../data/local/dao/inventory_dao.dart';
import '../../../data/providers.dart';
import '../../libraries/application/library_context.dart';

String _lib(Ref ref) {
  final lib = ref.watch(activeLibraryProvider);
  if (lib == null) throw const AppFailure('Tiada perpustakaan dipilih.');
  return lib.id;
}

final inventoryReportProvider =
    FutureProvider.autoDispose<InventoryReport>((ref) => ref.watch(inventoryDaoProvider).report(_lib(ref)));

final movementsProvider = StreamProvider.autoDispose.family<List<MovementView>, String?>(
  (ref, copyId) => ref.watch(inventoryDaoProvider).watchMovements(_lib(ref), copyId: copyId),
);

const movementLabels = {
  'acquisition': 'Perolehan',
  'status_change': 'Tukar status',
  'relocation': 'Pindah lokasi',
  'adjustment': 'Pelarasan',
  'removal': 'Dikeluarkan',
  'restoration': 'Dipulihkan',
};
