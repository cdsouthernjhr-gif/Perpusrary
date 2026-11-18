import 'package:drift/drift.dart';
import 'package:intl/intl.dart';

import '../../../core/xlsx/xlsx_writer.dart';
import '../../../data/local/dao/catalog_dao.dart';
import '../../../data/local/dao/inventory_dao.dart';
import '../../../data/local/database/app_database.dart';
import '../../../data/repositories/library_repositories.dart';
import '../../../shared/models/catalog_models.dart';

/// Builds the 8-worksheet export of ONE library from the device's database
/// (call after a sync for up-to-date data). Rows of other libraries are never
/// read: every query filters by [libraryId].
class ExcelExporter {
  ExcelExporter(this._db);
  final AppDatabase _db;

  static const sheetNames = [
    '01_Ringkasan',
    '02_Katalog_Buku',
    '03_Naskhah',
    '04_Kategori',
    '05_Lokasi_Rak',
    '06_Kemasukan',
    '07_Barcode',
    '08_Aktiviti',
  ];

  static String fileName(String libraryCode, DateTime at) =>
      'SmartLibrary_${libraryCode}_${DateFormat('yyyyMMdd_HHmm').format(at)}.xlsx';

  Future<Uint8List> build({
    required String libraryId,
    required String libraryName,
    required String libraryCode,
    required DateTime exportedAt,
    String? exportedBy,
    List<ActivityEntry>? activity, // null = not available (offline)
    Map<String, String> userNames = const {},
  }) async {
    final report = await InventoryDao(_db, CatalogDao(_db)).report(libraryId);
    final books = await (_db.select(_db.localBooks)
          ..where((b) => b.libraryId.equals(libraryId) & b.deletedAt.isNull())
          ..orderBy([(b) => OrderingTerm.asc(b.title)]))
        .get();
    final copies = await (_db.select(_db.localBookCopies)
          ..where((c) => c.libraryId.equals(libraryId) & c.deletedAt.isNull())
          ..orderBy([(c) => OrderingTerm.asc(c.barcode)]))
        .get();
    final categories = await (_db.select(_db.localCategories)
          ..where((c) => c.libraryId.equals(libraryId) & c.deletedAt.isNull())
          ..orderBy([(c) => OrderingTerm.asc(c.name)]))
        .get();
    final locations = await (_db.select(_db.localLocations)
          ..where((l) => l.libraryId.equals(libraryId) & l.deletedAt.isNull())
          ..orderBy([(l) => OrderingTerm.asc(l.rackCode), (l) => OrderingTerm.asc(l.shelfCode)]))
        .get();
    final movements = await (_db.select(_db.localStockMovements)
          ..where((m) => m.libraryId.equals(libraryId))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
        .get();
    final allCopies = {
      for (final c in await (_db.select(_db.localBookCopies)..where((c) => c.libraryId.equals(libraryId))).get())
        c.id: c,
    };
    final allLocations = {
      for (final l in await (_db.select(_db.localLocations)..where((l) => l.libraryId.equals(libraryId))).get())
        l.id: l,
    };

    final bookById = {for (final b in books) b.id: b};
    final allBooks = {
      for (final b in await (_db.select(_db.localBooks)..where((b) => b.libraryId.equals(libraryId))).get()) b.id: b,
    };
    final catName = {for (final c in categories) c.id: c.name};
    String loc(String? id) => id == null || allLocations[id] == null ? '' : locationLabel(allLocations[id]!);
    final copiesPerBook = <String, int>{};
    final copiesPerLocation = <String, int>{};
    for (final c in copies) {
      copiesPerBook[c.bookId] = (copiesPerBook[c.bookId] ?? 0) + 1;
      if (c.locationId != null) copiesPerLocation[c.locationId!] = (copiesPerLocation[c.locationId!] ?? 0) + 1;
    }
    final titlesPerCat = <String, int>{};
    final copiesPerCat = <String, int>{};
    for (final b in books) {
      if (b.categoryId != null) titlesPerCat[b.categoryId!] = (titlesPerCat[b.categoryId!] ?? 0) + 1;
    }
    for (final c in copies) {
      final cat = bookById[c.bookId]?.categoryId;
      if (cat != null) copiesPerCat[cat] = (copiesPerCat[cat] ?? 0) + 1;
    }
    double? money(int? cents) => cents == null ? null : cents / 100;
    String yn(bool v) => v ? 'Ya' : 'Tidak';
    const syncLabel = {'synced': 'Disegerakkan', 'pending': 'Menunggu sync', 'conflict': 'Konflik', 'rejected': 'Ditolak'};
    const moveLabel = {
      'acquisition': 'Perolehan',
      'status_change': 'Tukar status',
      'relocation': 'Pindah lokasi',
      'adjustment': 'Pelarasan',
      'removal': 'Dikeluarkan',
      'restoration': 'Dipulihkan',
    };
    String st(String? s) => s == null ? '' : CopyStatus.parse(s).label;

    final w = XlsxWriter();

    // 01 Ringkasan --------------------------------------------------------
    final summary = XlsxSheet(sheetNames[0], header: ['Perkara', 'Nilai'], autoFilter: false)
      ..preamble.addAll([
        ['Laporan SmartLibrary Manager'],
        ['Nama perpustakaan', libraryName],
        ['Kod perpustakaan', libraryCode],
        ['Tarikh eksport', exportedAt],
        ['Dieksport oleh', exportedBy ?? '-'],
        [
          'Perubahan belum disegerakkan',
          report.pendingChanges,
        ],
        [],
      ]);
    summary.rows.addAll([
      ['Jumlah judul', report.titles],
      ['Jumlah naskhah', report.copies],
      ['Naskhah dalam stok (tersedia + dalam proses)', report.inStock],
      for (final s in CopyStatus.values) ['Naskhah – ${s.label}', report.byStatus[s.value] ?? 0],
      ['Jumlah kategori', categories.length],
      ['Jumlah lokasi rak', locations.length],
      ['Nilai perolehan direkod (RM)', report.totalValueCents / 100],
    ]);
    w.addSheet(summary);

    // 02 Katalog ------------------------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[1], header: [
      'ID', 'Tajuk', 'Subjudul', 'ISBN', 'Pengarang', 'Penerbit', 'Tahun', 'Edisi', 'Bahasa', 'Kategori',
      'No. Panggilan', 'Jumlah Naskhah', 'Keterangan', 'Sumber Maklumat', 'Dicipta', 'Dikemas Kini',
    ], rows: [
      for (final b in books)
        [
          b.id, b.title, b.subtitle, b.isbn, b.author, b.publisher, b.publicationYear, b.edition, b.language,
          catName[b.categoryId], b.callNumber, copiesPerBook[b.id] ?? 0, b.description, b.metadataSource,
          b.createdAt, b.updatedAt,
        ],
    ]));

    // 03 Naskhah ------------------------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[2], header: [
      'Barcode', 'No. Perolehan', 'Tajuk', 'ISBN', 'Status', 'Keadaan', 'Lokasi', 'Tarikh Perolehan', 'Sumber',
      'Kos (RM)', 'Catatan', 'Status Sync',
    ], rows: [
      for (final c in copies)
        [
          c.barcode, c.accessionNumber, bookById[c.bookId]?.title, bookById[c.bookId]?.isbn, st(c.status),
          CopyCondition.parse(c.condition).label, loc(c.locationId), c.acquisitionDate,
          AcquisitionSource.tryParse(c.acquisitionSource)?.label, money(c.acquisitionCostCents), c.remarks,
          syncLabel[c.syncState] ?? c.syncState,
        ],
    ]));

    // 04 Kategori -----------------------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[3], header: ['Nama', 'Kod', 'Keterangan', 'Jumlah Judul', 'Jumlah Naskhah'], rows: [
      for (final c in categories) [c.name, c.code, c.description, titlesPerCat[c.id] ?? 0, copiesPerCat[c.id] ?? 0],
    ]));

    // 05 Lokasi -------------------------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[4],
        header: ['Bangunan', 'Bilik', 'Seksyen', 'Rak', 'Para', 'Keterangan', 'Jumlah Naskhah'],
        rows: [
          for (final l in locations)
            [l.building, l.room, l.section, l.rackCode, l.shelfCode, l.description, copiesPerLocation[l.id] ?? 0],
        ]));

    // 06 Kemasukan (stock movements) -------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[5], header: [
      'Tarikh', 'Jenis', 'Kuantiti', 'Barcode', 'Tajuk', 'Status Asal', 'Status Baharu', 'Lokasi Asal',
      'Lokasi Baharu', 'No. Rujukan', 'Catatan', 'Disahkan Pelayan',
    ], rows: [
      for (final m in movements)
        [
          m.createdAt, moveLabel[m.movementType] ?? m.movementType, m.quantity, allCopies[m.copyId]?.barcode,
          allBooks[allCopies[m.copyId]?.bookId]?.title, st(m.fromStatus), st(m.toStatus), loc(m.fromLocationId),
          loc(m.toLocationId), m.referenceNumber, m.remarks, yn(!m.provisional),
        ],
    ]));

    // 07 Barcode ------------------------------------------------------------
    w.addSheet(XlsxSheet(sheetNames[6], header: ['Barcode', 'No. Perolehan / Inventori', 'Tajuk', 'No. Panggilan', 'Lokasi'],
        rows: [
          for (final c in copies)
            [c.barcode, c.accessionNumber, bookById[c.bookId]?.title, bookById[c.bookId]?.callNumber, loc(c.locationId)],
        ]));

    // 08 Aktiviti -----------------------------------------------------------
    const actionLabel = {
      'create': 'Tambah',
      'update': 'Kemas kini',
      'soft_delete': 'Padam',
      'delete': 'Padam kekal',
      'restore': 'Pulih',
    };
    final act = XlsxSheet(sheetNames[7],
        header: ['Tarikh', 'Pengguna', 'Tindakan', 'Jenis Rekod', 'ID Rekod', 'Medan Berubah'],
        rows: [
          for (final a in activity ?? const <ActivityEntry>[])
            [
              a.createdAt.toLocal(), a.userId == null ? 'Sistem' : (userNames[a.userId] ?? a.userId),
              actionLabel[a.action] ?? a.action, a.entityType, a.entityId, a.changedFields.join(', '),
            ],
        ]);
    if (activity == null) {
      act.preamble.add(['Log aktiviti disimpan di pelayan dan tidak tersedia semasa luar talian.']);
    }
    w.addSheet(act);

    return w.build();
  }
}
