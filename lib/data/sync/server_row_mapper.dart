import 'package:drift/drift.dart';

import '../local/database/app_database.dart';

/// Converts server rows (sync_pull / server_row JSON) into local companions.
/// Server values are authoritative; sync_state becomes 'synced'.
abstract final class ServerRowMapper {
  static DateTime? _ts(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
  static DateTime _tsReq(Object? v) => _ts(v) ?? DateTime.now();
  static DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);
  static int? _int(Object? v) => v == null ? null : (v is num ? v.toInt() : int.parse('$v'));
  static int? _cents(Object? v) {
    if (v == null) return null;
    final d = v is num ? v.toDouble() : double.parse('$v');
    return (d * 100).round();
  }

  static LocalCategoriesCompanion category(Map<String, dynamic> r) => LocalCategoriesCompanion.insert(
        id: r['id'] as String,
        libraryId: r['library_id'] as String,
        name: r['name'] as String,
        code: Value(r['code'] as String?),
        description: Value(r['description'] as String?),
        serverVersion: Value(_int(r['version'])),
        syncState: const Value('synced'),
        createdAt: _tsReq(r['created_at']),
        updatedAt: _tsReq(r['updated_at']),
        deletedAt: Value(_ts(r['deleted_at'])),
      );

  static LocalLocationsCompanion location(Map<String, dynamic> r) => LocalLocationsCompanion.insert(
        id: r['id'] as String,
        libraryId: r['library_id'] as String,
        building: Value(r['building'] as String?),
        room: Value(r['room'] as String?),
        section: Value(r['section'] as String?),
        rackCode: r['rack_code'] as String,
        shelfCode: Value(r['shelf_code'] as String?),
        description: Value(r['description'] as String?),
        serverVersion: Value(_int(r['version'])),
        syncState: const Value('synced'),
        createdAt: _tsReq(r['created_at']),
        updatedAt: _tsReq(r['updated_at']),
        deletedAt: Value(_ts(r['deleted_at'])),
      );

  static LocalBooksCompanion book(Map<String, dynamic> r) => LocalBooksCompanion.insert(
        id: r['id'] as String,
        libraryId: r['library_id'] as String,
        title: r['title'] as String,
        subtitle: Value(r['subtitle'] as String?),
        isbn: Value(r['isbn'] as String?),
        author: Value(r['author'] as String?),
        publisher: Value(r['publisher'] as String?),
        publicationYear: Value(_int(r['publication_year'])),
        edition: Value(r['edition'] as String?),
        language: Value(r['language'] as String?),
        description: Value(r['description'] as String?),
        categoryId: Value(r['category_id'] as String?),
        callNumber: Value(r['call_number'] as String?),
        coverImagePath: Value(r['cover_image_path'] as String?),
        metadataSource: Value(r['metadata_source'] as String?),
        serverVersion: Value(_int(r['version'])),
        syncState: const Value('synced'),
        createdAt: _tsReq(r['created_at']),
        updatedAt: _tsReq(r['updated_at']),
        deletedAt: Value(_ts(r['deleted_at'])),
      );

  static LocalBookCopiesCompanion copy(Map<String, dynamic> r) => LocalBookCopiesCompanion.insert(
        id: r['id'] as String,
        libraryId: r['library_id'] as String,
        bookId: r['book_id'] as String,
        barcode: r['barcode'] as String,
        accessionNumber: Value(r['accession_number'] as String?),
        condition: Value(r['condition'] as String),
        locationId: Value(r['location_id'] as String?),
        acquisitionDate: Value(_date(r['acquisition_date'])),
        acquisitionSource: Value(r['acquisition_source'] as String?),
        acquisitionCostCents: Value(_cents(r['acquisition_cost'])),
        status: Value(r['status'] as String),
        remarks: Value(r['remarks'] as String?),
        serverVersion: Value(_int(r['version'])),
        syncState: const Value('synced'),
        createdAt: _tsReq(r['created_at']),
        updatedAt: _tsReq(r['updated_at']),
        deletedAt: Value(_ts(r['deleted_at'])),
      );

  static LocalStockMovementsCompanion movement(Map<String, dynamic> r) => LocalStockMovementsCompanion.insert(
        id: r['id'] as String,
        libraryId: r['library_id'] as String,
        copyId: r['copy_id'] as String,
        movementType: r['movement_type'] as String,
        quantity: _int(r['quantity'])!,
        fromStatus: Value(r['from_status'] as String?),
        toStatus: Value(r['to_status'] as String?),
        fromLocationId: Value(r['from_location_id'] as String?),
        toLocationId: Value(r['to_location_id'] as String?),
        referenceNumber: Value(r['reference_number'] as String?),
        remarks: Value(r['remarks'] as String?),
        createdBy: Value(r['created_by'] as String?),
        createdAt: _tsReq(r['created_at']),
        provisional: const Value(false),
      );
}
