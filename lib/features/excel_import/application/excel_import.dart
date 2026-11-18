import 'package:drift/drift.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/barcode.dart';
import '../../../core/utils/isbn.dart';
import '../../../core/xlsx/xlsx_reader.dart';
import '../../../core/xlsx/xlsx_writer.dart';
import '../../../data/local/dao/catalog_dao.dart';
import '../../../data/local/database/app_database.dart';
import '../../../shared/models/catalog_models.dart';

/// What to do when a row's title already exists in the library.
enum DuplicateMode {
  /// Leave the existing title unchanged; new copies (new barcodes) are still
  /// added to it; rows with nothing new are skipped.
  skip('skip', 'Abaikan pendua'),

  /// Update the existing title (non-empty cells) and existing copies (same barcode).
  update('update', 'Kemas kini rekod sedia ada'),

  /// Always create a new title record (e.g. a different edition).
  insertNew('insert_new', 'Tambah sebagai rekod baharu');

  const DuplicateMode(this.value, this.label);
  final String value;
  final String label;
}

class ImportOptions {
  const ImportOptions({
    this.duplicateMode = DuplicateMode.skip,
    this.createMissingCategories = true,
    this.createMissingLocations = true,
    this.generateMissingBarcodes = false,
  });
  final DuplicateMode duplicateMode;
  final bool createMissingCategories;
  final bool createMissingLocations;
  final bool generateMissingBarcodes;
}

enum RowAction { newBook, existingBook, updateBook, skip, error }

class ImportRow {
  ImportRow(this.rowNumber, this.values);
  final int rowNumber; // as shown in Excel
  final Map<String, Object?> values; // canonical column → cell value
  final errors = <String>[];
  final warnings = <String>[];

  // Resolved during planning
  RowAction action = RowAction.newBook;
  BookInput? book;
  String? existingBookId;
  CopyInput? copy;
  String? existingCopyId; // update mode
  String? categoryName;
  LocationInput? location;
  String? groupKey; // rows of the same title within the file

  bool get ok => errors.isEmpty;
}

class ImportPlan {
  ImportPlan({required this.fileName, required this.rows, required this.options, required this.fileWarnings});
  final String fileName;
  final List<ImportRow> rows;
  final ImportOptions options;
  final List<String> fileWarnings;
  final newCategories = <String>{};
  final newLocations = <String, LocationInput>{};

  int get total => rows.length;
  int get errorRows => rows.where((r) => !r.ok).length;
  int get validRows => rows.where((r) => r.ok && r.action != RowAction.skip).length;
  int get skippedRows => rows.where((r) => r.ok && r.action == RowAction.skip).length;
  int get newBooks => rows.where((r) => r.ok && r.action == RowAction.newBook).map((r) => r.groupKey).toSet().length;
  int get updatedBooks => rows.where((r) => r.ok && r.action == RowAction.updateBook).map((r) => r.existingBookId).toSet().length;
  int get newCopies => rows.where((r) => r.ok && r.action != RowAction.skip && r.copy != null && r.existingCopyId == null).length;
  int get updatedCopies => rows.where((r) => r.ok && r.existingCopyId != null).length;
}

class ImportResult {
  int booksCreated = 0;
  int booksUpdated = 0;
  int copiesCreated = 0;
  int copiesUpdated = 0;
  int skipped = 0;
  final failures = <(int, String)>[]; // (row, message)
  int get failed => failures.length;
}

/// Column definitions: canonical key → accepted header spellings (normalised:
/// lower-case, letters/digits only).
const importColumns = <String, List<String>>{
  'title': ['tajuk', 'title', 'judul'],
  'subtitle': ['subjudul', 'subtitle'],
  'isbn': ['isbn'],
  'author': ['pengarang', 'author', 'penulis'],
  'publisher': ['penerbit', 'publisher'],
  'year': ['tahun', 'tahunterbit', 'year', 'publicationyear'],
  'edition': ['edisi', 'edition'],
  'language': ['bahasa', 'language'],
  'category': ['kategori', 'category'],
  'call_number': ['nopanggilan', 'nomborpanggilan', 'callnumber'],
  'description': ['keterangan', 'description', 'sinopsis'],
  'barcode': ['barcode', 'kodbar'],
  'accession': ['noperolehan', 'nombornperolehan', 'nomborperolehan', 'noinventori', 'accession', 'accessionnumber'],
  'status': ['status'],
  'condition': ['keadaan', 'condition'],
  'building': ['bangunan', 'building'],
  'room': ['bilik', 'room'],
  'section': ['seksyen', 'section'],
  'rack': ['rak', 'kodrak', 'rack'],
  'shelf': ['para', 'kodpara', 'shelf'],
  'acquisition_date': ['tarikhperolehan', 'acquisitiondate'],
  'source': ['sumber', 'sumberperolehan', 'source'],
  'cost': ['kos', 'kosrm', 'harga', 'cost'],
  'remarks': ['catatan', 'remarks'],
};

/// Headers that try to choose the library — always ignored: the import goes
/// into the ACTIVE library only.
const _forbiddenHeaders = ['libraryid', 'perpustakaan', 'library', 'kodperpustakaan', 'librarycode'];

const templateHeaders = [
  'Tajuk', 'Subjudul', 'ISBN', 'Pengarang', 'Penerbit', 'Tahun', 'Edisi', 'Bahasa', 'Kategori', 'No Panggilan',
  'Keterangan', 'Barcode', 'No Perolehan', 'Status', 'Keadaan', 'Bangunan', 'Bilik', 'Seksyen', 'Rak', 'Para',
  'Tarikh Perolehan', 'Sumber', 'Kos', 'Catatan',
];

String _norm(Object? h) => '$h'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Template workbook: a "Buku" sheet (one row = one physical copy; rows of
/// the same title are grouped) and a "Panduan" sheet with allowed values.
Uint8List buildImportTemplate() {
  final w = XlsxWriter()
    ..addSheet(XlsxSheet('Buku', header: templateHeaders, rows: [
      ['Hikayat Hang Tuah', null, '9789836261234', 'Kassim Ahmad', 'Dewan Bahasa dan Pustaka', 1997, '2', 'Melayu',
        'Kesusasteraan', '899.2 HIK', null, 'B000101', 'P2026-0001', 'Tersedia', 'Baik', 'Blok A', 'Bilik Bacaan',
        'Fiksyen', 'R01', 'S1', DateTime(2026, 1, 15), 'Pembelian', 35.0, null],
      ['Hikayat Hang Tuah', null, '9789836261234', 'Kassim Ahmad', 'Dewan Bahasa dan Pustaka', 1997, '2', 'Melayu',
        'Kesusasteraan', '899.2 HIK', null, 'B000102', 'P2026-0002', 'Tersedia', 'Baik', 'Blok A', 'Bilik Bacaan',
        'Fiksyen', 'R01', 'S1', DateTime(2026, 1, 15), 'Sumbangan', null, 'Naskhah kedua'],
    ]))
    ..addSheet(XlsxSheet('Panduan', header: ['Medan', 'Keterangan / nilai dibenarkan'], autoFilter: false, rows: [
      ['Satu baris', 'Satu naskhah fizikal. Baris dengan Tajuk+ISBN yang sama digabungkan sebagai satu judul.'],
      ['Tajuk', 'Wajib.'],
      ['ISBN', '10 atau 13 digit (tanda sempang dibenarkan). ISBN-10 ditukar ke ISBN-13.'],
      ['Barcode', 'Unik dalam perpustakaan. ASCII tanpa ruang, maks 64. Kosong = judul sahaja (atau jana automatik).'],
      ['Status', CopyStatus.values.map((s) => s.label).join(', ')],
      ['Keadaan', CopyCondition.values.map((s) => s.label).join(', ')],
      ['Sumber', AcquisitionSource.values.map((s) => s.label).join(', ')],
      ['Tarikh Perolehan', 'Sel tarikh Excel, atau dd/mm/yyyy, atau yyyy-mm-dd.'],
      ['Kos', 'Nombor (RM), cth. 35.90'],
      ['Rak / Para', 'Lokasi dipadankan dengan Bangunan + Bilik + Seksyen + Rak + Para.'],
      ['Perpustakaan', 'TIDAK diambil daripada fail. Import sentiasa ke perpustakaan yang sedang dipilih.'],
    ]));
  return w.build();
}

/// Parses + validates an .xlsx against the ACTIVE library's local data.
class ImportPlanner {
  ImportPlanner(this._db, this.libraryId);
  final AppDatabase _db;
  final String libraryId;

  static const maxRows = 20000;

  Future<ImportPlan> plan(Uint8List bytes, String fileName, ImportOptions options) async {
    final tables = XlsxReader.read(bytes);
    final table = tables.firstWhere((t) => t.name.toLowerCase() == 'buku', orElse: () => tables.first);
    final fileWarnings = <String>[];

    // Header row = first row that contains a "title" column.
    var headerIndex = -1;
    Map<int, String> columns = {};
    for (var i = 0; i < table.rows.length && i < 20; i++) {
      final map = <int, String>{};
      for (var c = 0; c < table.rows[i].length; c++) {
        final n = _norm(table.rows[i][c]);
        for (final e in importColumns.entries) {
          if (e.value.contains(n)) map[c] = e.key;
        }
        if (_forbiddenHeaders.contains(n)) {
          fileWarnings.add('Kolum "${table.rows[i][c]}" diabaikan: import sentiasa ke perpustakaan yang sedang dipilih.');
        }
      }
      if (map.containsValue('title')) {
        headerIndex = i;
        columns = map;
        break;
      }
      fileWarnings.clear();
    }
    if (headerIndex < 0) {
      throw const AppFailure('Kolum "Tajuk" tidak dijumpai. Gunakan templat import.', code: 'bad_template');
    }
    final dataRows = table.rows.skip(headerIndex + 1).toList();
    if (dataRows.length > maxRows) {
      throw const AppFailure('Terlalu banyak baris (maksimum $maxRows). Pecahkan fail kepada beberapa bahagian.');
    }

    final rows = <ImportRow>[];
    for (var i = 0; i < dataRows.length; i++) {
      final r = dataRows[i];
      if (r.every((v) => v == null || '$v'.trim().isEmpty)) continue;
      rows.add(ImportRow(headerIndex + i + 2, {for (final e in columns.entries) e.value: e.key < r.length ? r[e.key] : null}));
    }

    final plan = ImportPlan(fileName: fileName, rows: rows, options: options, fileWarnings: fileWarnings);
    await _validate(plan);
    return plan;
  }

  static String? _s(Object? v) {
    if (v == null) return null;
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static String _key(String? v) => (v ?? '').toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static T? _enum<T>(String? raw, List<T> values, String Function(T) value, String Function(T) label) {
    if (raw == null) return null;
    final k = _key(raw);
    for (final v in values) {
      if (_key(value(v)) == k || _key(label(v)) == k) return v;
    }
    const aliases = {'available': 'available', 'ada': 'available', 'rosak': 'damaged', 'hilang': 'lost'};
    final a = aliases[k];
    if (a != null) {
      for (final v in values) {
        if (value(v) == a) return v;
      }
    }
    return null;
  }

  static DateTime? _date(Object? v, List<String> errors) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is num) return XlsxReader.fromSerial(v);
    final s = '$v'.trim();
    if (s.isEmpty) return null;
    // DateTime() silently rolls 31/31/2026 over into 2028 — reject instead.
    DateTime? strict(int y, int m, int d) {
      final dt = DateTime(y, m, d);
      return (dt.year == y && dt.month == m && dt.day == d) ? dt : null;
    }

    final dmy = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$').firstMatch(s);
    final ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
    final parsed = dmy != null
        ? strict(int.parse(dmy[3]!), int.parse(dmy[2]!), int.parse(dmy[1]!))
        : ymd != null
            ? strict(int.parse(ymd[1]!), int.parse(ymd[2]!), int.parse(ymd[3]!))
            : null;
    if (parsed != null) return parsed;
    errors.add('Tarikh perolehan "$s" tidak difahami (guna dd/mm/yyyy).');
    return null;
  }

  Future<void> _validate(ImportPlan plan) async {
    final opts = plan.options;
    final books = await (_db.select(_db.localBooks)..where((b) => b.libraryId.equals(libraryId) & b.deletedAt.isNull()))
        .get();
    final copies = await (_db.select(_db.localBookCopies)..where((c) => c.libraryId.equals(libraryId))).get();
    final cats = await (_db.select(_db.localCategories)
          ..where((c) => c.libraryId.equals(libraryId) & c.deletedAt.isNull()))
        .get();
    final locs = await (_db.select(_db.localLocations)
          ..where((l) => l.libraryId.equals(libraryId) & l.deletedAt.isNull()))
        .get();

    final copyByBarcode = {for (final c in copies) c.barcode: c};
    final copyByAccession = {for (final c in copies) if (c.accessionNumber != null) c.accessionNumber!: c};
    final catByName = {for (final c in cats) _key(c.name): c};
    String locKey(String? b, String? r, String? s, String rack, String? shelf) =>
        [b, r, s, rack, shelf].map(_key).join('|');
    final locByKey = {for (final l in locs) locKey(l.building, l.room, l.section, l.rackCode, l.shelfCode): l};
    final bookByIsbn = <String, LocalBook>{for (final b in books) if (b.isbn != null) b.isbn!: b};
    final bookByTitleAuthor = <String, LocalBook>{for (final b in books) '${_key(b.title)}|${_key(b.author)}': b};

    final seenBarcodes = <String, int>{};
    final seenAccessions = <String, int>{};

    for (final row in plan.rows) {
      final v = row.values;
      final e = row.errors;
      final title = _s(v['title']);
      if (title == null) e.add('Tajuk diperlukan.');

      final isbnRaw = _s(v['isbn']);
      final isbn = Isbn.canonical(isbnRaw);
      if (isbnRaw != null) {
        final err = Isbn.validate(isbnRaw);
        if (err != null) {
          e.add('ISBN "$isbnRaw": $err');
        } else if (Isbn.checksumWarning(isbnRaw) != null) {
          row.warnings.add('ISBN "$isbnRaw": digit semak tidak sah.');
        }
      }

      int? year;
      final yearRaw = v['year'];
      if (yearRaw != null && _s(yearRaw) != null) {
        year = yearRaw is num ? yearRaw.toInt() : int.tryParse(_s(yearRaw)!);
        if (year == null || year < 1000 || year > 2200) e.add('Tahun "${_s(yearRaw)}" tidak sah.');
      }

      // Category
      final catName = _s(v['category']);
      String? categoryId;
      if (catName != null) {
        final hit = catByName[_key(catName)];
        if (hit != null) {
          categoryId = hit.id;
        } else if (opts.createMissingCategories) {
          plan.newCategories.add(catName);
          row.categoryName = catName;
        } else {
          e.add('Kategori "$catName" tidak wujud.');
        }
      }

      // Location
      String? locationId;
      final rack = _s(v['rack']);
      final anyLoc = ['building', 'room', 'section', 'shelf'].any((k) => _s(v[k]) != null);
      if (rack == null && anyLoc) e.add('Kod Rak diperlukan apabila lokasi diisi.');
      if (rack != null) {
        final li = LocationInput(
            building: _s(v['building']), room: _s(v['room']), section: _s(v['section']), rackCode: rack, shelfCode: _s(v['shelf']));
        final k = locKey(li.building, li.room, li.section, li.rackCode, li.shelfCode);
        final hit = locByKey[k];
        if (hit != null) {
          locationId = hit.id;
        } else if (opts.createMissingLocations) {
          plan.newLocations[k] = li;
          row.location = li;
        } else {
          e.add('Lokasi rak "${locationLabelOf(li)}" tidak wujud.');
        }
      }

      // Copy fields
      var barcode = _s(v['barcode']);
      final accession = _s(v['accession']);
      final status = _enum(_s(v['status']), CopyStatus.values, (s) => s.value, (s) => s.label);
      if (_s(v['status']) != null && status == null) e.add('Status "${_s(v['status'])}" tidak dikenali.');
      final condition = _enum(_s(v['condition']), CopyCondition.values, (s) => s.value, (s) => s.label);
      if (_s(v['condition']) != null && condition == null) e.add('Keadaan "${_s(v['condition'])}" tidak dikenali.');
      final source = _enum(_s(v['source']), AcquisitionSource.values, (s) => s.value, (s) => s.label);
      if (_s(v['source']) != null && source == null) e.add('Sumber "${_s(v['source'])}" tidak dikenali.');
      final date = _date(v['acquisition_date'], e);
      int? cents;
      final costRaw = v['cost'];
      if (costRaw != null && _s(costRaw) != null) {
        final n = costRaw is num ? costRaw.toDouble() : double.tryParse(_s(costRaw)!.replaceAll(RegExp(r'rm|\s', caseSensitive: false), '').replaceAll(',', '.'));
        if (n == null || n < 0) {
          e.add('Kos "${_s(costRaw)}" tidak sah.');
        } else {
          cents = (n * 100).round();
        }
      }

      if (barcode != null) {
        final err = CopyBarcode.validate(barcode);
        if (err != null) e.add('Barcode "$barcode": $err');
        final first = seenBarcodes[barcode];
        if (first != null) {
          e.add('Barcode "$barcode" berulang dalam fail (baris $first).');
        } else {
          seenBarcodes[barcode] = row.rowNumber;
        }
        final existing = copyByBarcode[barcode];
        if (existing != null) {
          if (opts.duplicateMode == DuplicateMode.update && existing.deletedAt == null) {
            row.existingCopyId = existing.id;
          } else {
            e.add('Barcode "$barcode" sudah digunakan dalam perpustakaan ini.');
          }
        }
      }
      if (accession != null) {
        final first = seenAccessions[accession];
        if (first != null) e.add('No. perolehan "$accession" berulang dalam fail (baris $first).');
        seenAccessions[accession] ??= row.rowNumber;
        final existing = copyByAccession[accession];
        if (existing != null && existing.id != row.existingCopyId) {
          e.add('No. perolehan "$accession" sudah digunakan.');
        }
      }

      if (title == null) {
        row.action = RowAction.error;
        continue;
      }
      row.book = BookInput(
        title: title,
        subtitle: _s(v['subtitle']),
        isbn: isbn,
        author: _s(v['author']),
        publisher: _s(v['publisher']),
        publicationYear: year,
        edition: _s(v['edition']),
        language: _s(v['language']),
        description: _s(v['description']),
        categoryId: categoryId,
        callNumber: _s(v['call_number']),
        metadataSource: 'import',
      );
      row.groupKey = isbn != null ? 'isbn:$isbn' : 'ta:${_key(title)}|${_key(_s(v['author']))}';
      if (barcode == null && opts.generateMissingBarcodes) barcode = '';
      if (barcode != null) {
        row.copy = CopyInput(
          barcode: barcode, // '' = generate at import time
          accessionNumber: accession,
          status: status ?? CopyStatus.available,
          condition: condition ?? CopyCondition.good,
          locationId: locationId,
          acquisitionDate: date,
          acquisitionSource: source,
          acquisitionCostCents: cents,
          remarks: _s(v['remarks']),
        );
      }

      final existingBook = isbn != null ? bookByIsbn[isbn] : bookByTitleAuthor['${_key(title)}|${_key(_s(v['author']))}'];
      if (existingBook != null && opts.duplicateMode != DuplicateMode.insertNew) {
        row.existingBookId = existingBook.id;
        if (opts.duplicateMode == DuplicateMode.update) {
          row.action = RowAction.updateBook;
        } else if (row.copy != null && row.existingCopyId == null) {
          row.action = RowAction.existingBook;
          row.warnings.add('Judul sudah wujud – naskhah ditambah pada rekod sedia ada.');
        } else {
          row.action = RowAction.skip;
          row.warnings.add('Pendua – diabaikan.');
        }
      } else {
        row.action = RowAction.newBook;
      }
      if (!row.ok) row.action = RowAction.error;
    }
  }

  static String locationLabelOf(LocationInput l) =>
      [l.building, l.room, l.section, 'Rak ${l.rackCode}', if (l.shelfCode != null) 'Para ${l.shelfCode}']
          .whereType<String>()
          .join(' › ');
}

/// Executes a plan through CatalogDao (local-first: everything goes to the
/// outbox and is synced like manual edits). Rows are processed in batches;
/// each batch is one transaction, and a failing row is recorded without
/// aborting other batches.
class ImportExecutor {
  ImportExecutor(this._db, this._dao, {required this.libraryId, required this.libraryCode, required this.deviceId});
  final AppDatabase _db;
  final CatalogDao _dao;
  final String libraryId;
  final String libraryCode;
  final String deviceId;

  static const batchSize = 100;

  Future<ImportResult> run(ImportPlan plan, {void Function(int done, int total)? onProgress}) async {
    final result = ImportResult();
    final meta = MovementMeta(referenceNumber: _ref(plan.fileName));

    // 1. Create missing categories / locations (once).
    final catIds = <String, String>{};
    for (final name in plan.newCategories) {
      catIds[name.toLowerCase()] = await _dao.saveCategory(libraryId, CategoryInput(name: name));
    }
    final locIds = <LocationInput, String>{};
    for (final l in plan.newLocations.values) {
      locIds[l] = await _dao.saveLocation(libraryId, l);
    }

    final createdBooks = <String, String>{}; // groupKey → new book id
    final updatedBooks = <String>{};
    final rows = plan.rows.where((r) => r.ok).toList();
    result.skipped = rows.where((r) => r.action == RowAction.skip).length;
    final todo = rows.where((r) => r.action != RowAction.skip).toList();

    for (var start = 0; start < todo.length; start += batchSize) {
      final batch = todo.sublist(start, (start + batchSize).clamp(0, todo.length));
      // One SQLite transaction (one commit / fsync) per batch; each row runs in
      // a nested transaction (savepoint) so a failing row is rolled back alone.
      await _db.transaction(() async {
      for (final row in batch) {
        // Effects are applied to the shared state only after the row commits
        // its savepoint: a rolled-back row must leave no trace (no counters,
        // no cached book id that later rows of the same title would reuse).
        String? newBook;
        String? updatedBook;
        var copyCreated = false;
        var copyUpdated = false;
        try {
          await _db.transaction(() async {
            var book = row.book!;
            if (row.categoryName != null) {
              book = _withCategory(book, catIds[row.categoryName!.toLowerCase()]);
            }
            String bookId;
            switch (row.action) {
              case RowAction.newBook:
                final existing = createdBooks[row.groupKey];
                if (existing != null) {
                  bookId = existing;
                } else {
                  bookId = await _dao.createBook(libraryId, book);
                  newBook = bookId;
                }
              case RowAction.updateBook:
                bookId = row.existingBookId!;
                if (!updatedBooks.contains(bookId)) {
                  final current = await (_db.select(_db.localBooks)..where((b) => b.id.equals(bookId))).getSingle();
                  await _dao.updateBook(libraryId, bookId, _merge(current, book));
                  updatedBook = bookId;
                }
              default:
                bookId = row.existingBookId!;
            }
            final c = row.copy;
            if (c == null) return;
            final locationId = row.location != null ? locIds[row.location] : c.locationId;
            if (row.existingCopyId != null) {
              final cur = await (_db.select(_db.localBookCopies)..where((x) => x.id.equals(row.existingCopyId!))).getSingle();
              await _dao.updateCopy(
                libraryId,
                cur.id,
                CopyInput(
                  barcode: cur.barcode,
                  accessionNumber: c.accessionNumber ?? cur.accessionNumber,
                  condition: c.condition,
                  status: c.status,
                  locationId: locationId ?? cur.locationId,
                  acquisitionDate: c.acquisitionDate ?? cur.acquisitionDate,
                  acquisitionSource: c.acquisitionSource ?? AcquisitionSource.tryParse(cur.acquisitionSource),
                  acquisitionCostCents: c.acquisitionCostCents ?? cur.acquisitionCostCents,
                  remarks: c.remarks ?? cur.remarks,
                ),
                meta: meta,
              );
              copyUpdated = true;
            } else {
              final barcode = c.barcode.isEmpty
                  ? await _dao.nextGeneratedBarcode(libraryId: libraryId, libraryCode: libraryCode, deviceId: deviceId)
                  : c.barcode;
              await _dao.addCopy(
                libraryId,
                bookId,
                CopyInput(
                  barcode: barcode,
                  accessionNumber: c.accessionNumber,
                  condition: c.condition,
                  status: c.status,
                  locationId: locationId,
                  acquisitionDate: c.acquisitionDate,
                  acquisitionSource: c.acquisitionSource,
                  acquisitionCostCents: c.acquisitionCostCents,
                  remarks: c.remarks,
                ),
                meta: meta,
              );
              copyCreated = true;
            }
          });
          if (newBook != null) {
            createdBooks[row.groupKey!] = newBook!;
            result.booksCreated++;
          }
          if (updatedBook != null && updatedBooks.add(updatedBook!)) result.booksUpdated++;
          if (copyCreated) result.copiesCreated++;
          if (copyUpdated) result.copiesUpdated++;
        } catch (e) {
          result.failures.add((row.rowNumber, AppFailure.from(e).message));
        }
      }
      });
      onProgress?.call((start + batch.length).clamp(0, todo.length), todo.length);
    }
    return result;
  }

  static String _ref(String fileName) {
    final s = 'Import $fileName';
    return s.length > 100 ? s.substring(0, 100) : s;
  }

  static BookInput _withCategory(BookInput b, String? categoryId) => BookInput(
        title: b.title,
        subtitle: b.subtitle,
        isbn: b.isbn,
        author: b.author,
        publisher: b.publisher,
        publicationYear: b.publicationYear,
        edition: b.edition,
        language: b.language,
        description: b.description,
        categoryId: categoryId ?? b.categoryId,
        callNumber: b.callNumber,
        metadataSource: b.metadataSource,
      );

  /// Update mode: non-empty cells overwrite, empty cells keep current data.
  static BookInput _merge(LocalBook cur, BookInput n) => BookInput(
        title: n.title,
        subtitle: n.subtitle ?? cur.subtitle,
        isbn: n.isbn ?? cur.isbn,
        author: n.author ?? cur.author,
        publisher: n.publisher ?? cur.publisher,
        publicationYear: n.publicationYear ?? cur.publicationYear,
        edition: n.edition ?? cur.edition,
        language: n.language ?? cur.language,
        description: n.description ?? cur.description,
        categoryId: n.categoryId ?? cur.categoryId,
        callNumber: n.callNumber ?? cur.callNumber,
        coverImagePath: cur.coverImagePath,
        metadataSource: cur.metadataSource ?? 'import',
      );
}
