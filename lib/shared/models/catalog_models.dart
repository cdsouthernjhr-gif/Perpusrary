import '../../data/local/database/app_database.dart';

/// Copy status values (same CHECK as the server). No loan statuses: loans
/// are out of scope for this version.
enum CopyStatus {
  available('available', 'Tersedia'),
  inProcessing('in_processing', 'Dalam proses'),
  damaged('damaged', 'Rosak'),
  lost('lost', 'Hilang'),
  inactive('inactive', 'Tidak aktif');

  const CopyStatus(this.value, this.label);
  final String value;
  final String label;

  static CopyStatus parse(String v) => values.firstWhere((s) => s.value == v, orElse: () => available);
}

enum CopyCondition {
  newCopy('new', 'Baharu'),
  good('good', 'Baik'),
  fair('fair', 'Sederhana'),
  poor('poor', 'Lemah'),
  damaged('damaged', 'Rosak');

  const CopyCondition(this.value, this.label);
  final String value;
  final String label;

  static CopyCondition parse(String v) => values.firstWhere((s) => s.value == v, orElse: () => good);
}

enum AcquisitionSource {
  purchase('purchase', 'Pembelian'),
  donation('donation', 'Sumbangan'),
  grant('grant', 'Geran'),
  exchange('exchange', 'Pertukaran'),
  other('other', 'Lain-lain');

  const AcquisitionSource(this.value, this.label);
  final String value;
  final String label;

  static AcquisitionSource? tryParse(String? v) {
    for (final s in values) {
      if (s.value == v) return s;
    }
    return null;
  }
}

class CategoryInput {
  const CategoryInput({required this.name, this.code, this.description});
  final String name;
  final String? code;
  final String? description;
}

class LocationInput {
  const LocationInput({
    required this.rackCode,
    this.building,
    this.room,
    this.section,
    this.shelfCode,
    this.description,
  });
  final String? building;
  final String? room;
  final String? section;
  final String rackCode;
  final String? shelfCode;
  final String? description;
}

class BookInput {
  const BookInput({
    required this.title,
    this.subtitle,
    this.isbn,
    this.author,
    this.publisher,
    this.publicationYear,
    this.edition,
    this.language,
    this.description,
    this.categoryId,
    this.callNumber,
    this.coverImagePath,
    this.metadataSource = 'manual',
  });

  final String title;
  final String? subtitle;
  final String? isbn; // canonical (see Isbn.canonical)
  final String? author;
  final String? publisher;
  final int? publicationYear;
  final String? edition;
  final String? language;
  final String? description;
  final String? categoryId;
  final String? callNumber;
  final String? coverImagePath;
  final String metadataSource;
}

class CopyInput {
  const CopyInput({
    required this.barcode,
    this.accessionNumber,
    this.condition = CopyCondition.good,
    this.status = CopyStatus.available,
    this.locationId,
    this.acquisitionDate,
    this.acquisitionSource,
    this.acquisitionCostCents,
    this.remarks,
  });

  final String barcode;
  final String? accessionNumber;
  final CopyCondition condition;
  final CopyStatus status;
  final String? locationId;
  final DateTime? acquisitionDate;
  final AcquisitionSource? acquisitionSource;
  final int? acquisitionCostCents;
  final String? remarks;

  CopyInput copyWith({String? barcode}) => CopyInput(
        barcode: barcode ?? this.barcode,
        accessionNumber: accessionNumber,
        condition: condition,
        status: status,
        locationId: locationId,
        acquisitionDate: acquisitionDate,
        acquisitionSource: acquisitionSource,
        acquisitionCostCents: acquisitionCostCents,
        remarks: remarks,
      );
}

/// Optional inventory reference recorded with a copy change
/// (becomes stock_movements.reference_number / remarks on the server).
class MovementMeta {
  const MovementMeta({this.referenceNumber, this.remarks});
  final String? referenceNumber;
  final String? remarks;

  Map<String, dynamic>? toJson() {
    final m = {
      if (referenceNumber?.trim().isNotEmpty ?? false) 'reference_number': referenceNumber!.trim(),
      if (remarks?.trim().isNotEmpty ?? false) 'remarks': remarks!.trim(),
    };
    return m.isEmpty ? null : m;
  }
}

class BookListItem {
  const BookListItem({required this.book, required this.copyCount, this.categoryName});
  final LocalBook book;
  final int copyCount;
  final String? categoryName;
}

class CopyListItem {
  const CopyListItem({required this.copy, this.location});
  final LocalBookCopy copy;
  final LocalLocation? location;
}

class DuplicateCandidate {
  const DuplicateCandidate({required this.book, required this.score, required this.reasons});
  final LocalBook book;
  final double score;
  final List<String> reasons; // isbn, title, author, publisher, year
}

String locationLabel(LocalLocation l) => [
      if (l.building?.isNotEmpty ?? false) l.building,
      if (l.room?.isNotEmpty ?? false) l.room,
      if (l.section?.isNotEmpty ?? false) l.section,
      'Rak ${l.rackCode}',
      if (l.shelfCode?.isNotEmpty ?? false) 'Para ${l.shelfCode}',
    ].join(' › ');
