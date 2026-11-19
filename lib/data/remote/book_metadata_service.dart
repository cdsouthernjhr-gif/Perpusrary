import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../core/utils/isbn.dart';

/// Bibliographic data suggested from a public catalogue. The user always
/// reviews it before saving; registration works without it.
class BookMetadata {
  const BookMetadata({
    required this.source,
    this.title,
    this.subtitle,
    this.authors = const [],
    this.publisher,
    this.publicationYear,
    this.edition,
    this.language,
    this.description,
    this.coverUrl,
    this.isbn,
    this.callNumber,
    this.sources = const [],
  });

  /// Main source (stored as books.metadata_source):
  /// google_books | open_library | library_of_congress
  final String source;
  final String? title;
  final String? subtitle;
  final List<String> authors;
  final String? publisher;
  final int? publicationYear;
  final String? edition;
  final String? language;
  final String? description;
  final String? coverUrl;
  final String? isbn;

  /// Dewey (DDC) number when the catalogue has one.
  final String? callNumber;

  /// Every source that contributed at least one field, main source first.
  final List<String> sources;

  String? get author => authors.isEmpty ? null : authors.join(', ');

  static const sourceLabels = {
    'google_books': 'Google Books',
    'open_library': 'Open Library',
    'library_of_congress': 'Library of Congress',
  };

  static String labelOf(String source) => sourceLabels[source] ?? source;

  /// Fills fields missing here from [other] (never overwrites).
  BookMetadata mergedWith(BookMetadata other) {
    String? pick(String? a, String? b) => (a != null && a.trim().isNotEmpty) ? a : b;
    final before = [title, subtitle, author, publisher, publicationYear, edition, language, description, coverUrl, callNumber];
    final merged = BookMetadata(
      source: source,
      isbn: isbn ?? other.isbn,
      title: pick(title, other.title),
      subtitle: pick(subtitle, other.subtitle),
      authors: authors.isNotEmpty ? authors : other.authors,
      publisher: pick(publisher, other.publisher),
      publicationYear: publicationYear ?? other.publicationYear,
      edition: pick(edition, other.edition),
      language: pick(language, other.language),
      description: pick(description, other.description),
      coverUrl: pick(coverUrl, other.coverUrl),
      callNumber: pick(callNumber, other.callNumber),
      sources: sources,
    );
    final after = [merged.title, merged.subtitle, merged.author, merged.publisher, merged.publicationYear,
        merged.edition, merged.language, merged.description, merged.coverUrl, merged.callNumber];
    var contributed = false;
    for (var i = 0; i < before.length; i++) {
      if (before[i] != after[i]) contributed = true;
    }
    if (!contributed) return merged;
    return BookMetadata(
      source: merged.source,
      isbn: merged.isbn,
      title: merged.title,
      subtitle: merged.subtitle,
      authors: merged.authors,
      publisher: merged.publisher,
      publicationYear: merged.publicationYear,
      edition: merged.edition,
      language: merged.language,
      description: merged.description,
      coverUrl: merged.coverUrl,
      callNumber: merged.callNumber,
      sources: [...sources, other.source],
    );
  }
}

/// Outcome of a lookup across all catalogues.
class MetadataLookup {
  const MetadataLookup({this.book, this.unreachable = const []});

  /// Merged result, or null when no catalogue knows the ISBN.
  final BookMetadata? book;

  /// Catalogues that could not be asked (offline, timeout, rate limit, server
  /// error). When non-empty, "not found" may simply mean "not checked".
  final List<String> unreachable;

  bool get found => book != null;
}

class _SourceResult {
  const _SourceResult(this.data, {this.failed = false});
  final BookMetadata? data;
  final bool failed;
}

class _HttpFailure implements Exception {
  const _HttpFailure();
}

/// Looks an ISBN up in Google Books, Open Library and the Library of Congress
/// catalogue AT THE SAME TIME, trying both the ISBN-13 and ISBN-10 forms, and
/// merges the answers (Google Books first, then Open Library, then LoC fill
/// gaps). LoC is the strongest open source for Malaysian/Southeast Asian
/// publications (its Jakarta office acquires them).
///
/// Only the ISBN is sent (no user or library data). No catalogue has every
/// book — many local titles are in none of them — so manual entry always
/// remains available.
class BookMetadataService {
  BookMetadataService({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.googleApiKey = const String.fromEnvironment('GOOGLE_BOOKS_API_KEY'),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// Optional (dart-define GOOGLE_BOOKS_API_KEY). Without it Google Books
  /// applies a small anonymous per-IP quota. Restrict the key to this Android
  /// app + Books API in Google Cloud Console.
  final String googleApiKey;

  static const _headers = {
    'Accept': 'application/json',
    'User-Agent': 'SmartLibraryManager/1.0 (Android; ISBN lookup)',
  };

  /// Convenience: merged metadata or null.
  Future<BookMetadata?> lookup(String rawIsbn) async => (await search(rawIsbn)).book;

  Future<MetadataLookup> search(String rawIsbn) async {
    final isbn13 = Isbn.canonical(rawIsbn);
    if (isbn13 == null || !Isbn.matchesDbFormat(isbn13)) return const MetadataLookup();
    // Every form the catalogues may have indexed the book under.
    final isbn10 = isbn13.length == 13 ? Isbn.to10(isbn13) : null;
    final forms = [isbn13, ?isbn10];

    final results = await Future.wait([
      _guard('google_books', () => _google(isbn13, forms)),
      _guard('open_library', () => _openLibrary(isbn13, forms)),
      _guard('library_of_congress', () => _libraryOfCongress(isbn13, forms)),
    ]);
    const names = ['google_books', 'open_library', 'library_of_congress'];

    BookMetadata? merged;
    final unreachable = <String>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.failed) unreachable.add(names[i]);
      final d = r.data;
      if (d == null || (d.title ?? '').trim().isEmpty) continue;
      merged = merged == null ? d : merged.mergedWith(d);
    }
    return MetadataLookup(book: merged, unreachable: unreachable);
  }

  Future<_SourceResult> _guard(String name, Future<BookMetadata?> Function() run) async {
    try {
      return _SourceResult(await run().timeout(timeout + const Duration(seconds: 2)));
    } on Object {
      return const _SourceResult(null, failed: true);
    }
  }

  /// GET; 404 → null (not found). Network errors, timeouts, 429 and 5xx
  /// throw [_HttpFailure] so the caller can report "could not check".
  Future<String?> _get(Uri uri, {Map<String, String> headers = _headers}) async {
    final http.Response res;
    try {
      res = await _client.get(uri, headers: headers).timeout(timeout);
    } on Object {
      throw const _HttpFailure();
    }
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw const _HttpFailure();
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final body = await _get(uri);
    if (body == null) return null;
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      throw const _HttpFailure();
    }
  }

  // ------------------------------------------------------------ Google Books

  Future<BookMetadata?> _google(String isbn13, List<String> forms) async {
    for (final f in forms) {
      final json = await _getJson(Uri.https('www.googleapis.com', '/books/v1/volumes', {
        'q': 'isbn:$f',
        'maxResults': '5',
        if (googleApiKey.isNotEmpty) 'key': googleApiKey,
      }));
      final items = json?['items'];
      if (items is! List || items.isEmpty) continue;
      final infos = items
          .whereType<Map<String, dynamic>>()
          .map((i) => i['volumeInfo'])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (infos.isEmpty) continue;
      // Prefer the volume that really carries this ISBN.
      bool carries(Map<String, dynamic> info) => ((info['industryIdentifiers'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .any((id) => forms.contains(Isbn.normalize(id['identifier']?.toString())));
      final info = infos.firstWhere(carries, orElse: () => infos.first);
      final images = info['imageLinks'];
      String? cover = images is Map ? (images['thumbnail'] ?? images['smallThumbnail']) as String? : null;
      if (cover != null && cover.startsWith('http://')) cover = cover.replaceFirst('http://', 'https://');
      return BookMetadata(
        source: 'google_books',
        sources: const ['google_books'],
        isbn: isbn13,
        title: _clean(info['title'] as String?),
        subtitle: _clean(info['subtitle'] as String?),
        authors: ((info['authors'] as List?) ?? const []).whereType<String>().map((a) => a.trim()).toList(),
        publisher: _clean(info['publisher'] as String?),
        publicationYear: _year(info['publishedDate'] as String?),
        language: info['language'] as String?,
        description: _clean(info['description'] as String?),
        coverUrl: cover,
      );
    }
    return null;
  }

  // ------------------------------------------------------------ Open Library

  Future<BookMetadata?> _openLibrary(String isbn13, List<String> forms) async {
    final json = await _getJson(Uri.https('openlibrary.org', '/api/books', {
      'bibkeys': forms.map((f) => 'ISBN:$f').join(','),
      'format': 'json',
      'jscmd': 'data',
    }));
    if (json == null) return null;
    Map<String, dynamic>? data;
    for (final f in forms) {
      final d = json['ISBN:$f'];
      if (d is Map<String, dynamic>) {
        data = d;
        break;
      }
    }
    if (data == null) return null;
    List<String> names(Object? list) =>
        ((list as List?) ?? const []).whereType<Map<String, dynamic>>().map((m) => m['name']).whereType<String>().toList();
    final publishers = names(data['publishers']);
    // Open Library sometimes lists the publisher as an "author".
    bool isPublisher(String a) {
      final x = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      return publishers.any((p) {
        final y = p.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        return x.isNotEmpty && y.isNotEmpty && (y.startsWith(x) || x.startsWith(y));
      });
    }

    final cover = data['cover'];
    final classes = data['classifications'];
    final dewey = classes is Map ? (classes['dewey_decimal_class'] as List?)?.whereType<String>().firstOrNull : null;
    return BookMetadata(
      source: 'open_library',
      sources: const ['open_library'],
      isbn: isbn13,
      title: _clean(data['title'] as String?),
      subtitle: _clean(data['subtitle'] as String?),
      authors: names(data['authors']).where((a) => !isPublisher(a)).toList(),
      publisher: publishers.firstOrNull,
      publicationYear: _year(data['publish_date'] as String?),
      coverUrl: cover is Map ? (cover['medium'] ?? cover['small']) as String? : null,
      callNumber: dewey,
    );
  }

  // ------------------------------------------------ Library of Congress (SRU)

  Future<BookMetadata?> _libraryOfCongress(String isbn13, List<String> forms) async {
    final body = await _get(
      Uri.https('lx2.loc.gov', '/sru/lcdb', {
        'version': '1.1',
        'operation': 'searchRetrieve',
        'query': forms.map((f) => 'bath.isbn=$f').join(' or '),
        'maximumRecords': '1',
        'recordSchema': 'mods',
      }),
      headers: const {'Accept': 'application/xml', 'User-Agent': 'SmartLibraryManager/1.0 (Android; ISBN lookup)'},
    );
    if (body == null) return null;
    return parseLocMods(body, isbn13);
  }

  /// Parses one MODS record from an LoC SRU response. Public for tests.
  static BookMetadata? parseLocMods(String xml, String isbn13) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException {
      throw const _HttpFailure();
    }
    final mods = doc.findAllElements('mods').firstOrNull;
    if (mods == null) return null;
    Iterable<XmlElement> kids(XmlElement e, String name) => e.childElements.where((c) => c.localName == name);
    String? text(XmlElement? e) => e == null ? null : _clean(e.innerText);

    final titleInfo = kids(mods, 'titleInfo').where((t) => t.getAttribute('type') == null).firstOrNull ??
        kids(mods, 'titleInfo').firstOrNull;
    final nonSort = text(titleInfo == null ? null : kids(titleInfo, 'nonSort').firstOrNull);
    var title = text(titleInfo == null ? null : kids(titleInfo, 'title').firstOrNull);
    if (title != null && nonSort != null) title = '$nonSort $title'.replaceAll(RegExp(r'\s+'), ' ');
    final subtitle = text(titleInfo == null ? null : kids(titleInfo, 'subTitle').firstOrNull);

    final authors = <String>[];
    for (final n in kids(mods, 'name')) {
      final roles = n.findAllElements('roleTerm').map((r) => r.innerText.trim().toLowerCase()).toList();
      final isAuthor = n.getAttribute('usage') == 'primary' || roles.isEmpty || roles.any((r) => r.startsWith('author') || r == 'aut');
      if (!isAuthor) continue;
      final parts = kids(n, 'namePart').where((p) => p.getAttribute('type') == null).map((p) => _clean(p.innerText)).nonNulls;
      final name = parts.join(' ');
      if (name.isNotEmpty) authors.add(name);
    }

    String? publisher;
    String? edition;
    int? year;
    for (final o in kids(mods, 'originInfo')) {
      publisher ??= text(kids(o, 'publisher').firstOrNull) ??
          text(o.findAllElements('agent').expand((a) => kids(a, 'namePart')).firstOrNull);
      edition ??= text(kids(o, 'edition').firstOrNull);
      for (final d in kids(o, 'dateIssued')) {
        year ??= _year(d.innerText);
      }
    }

    // Edited/corporate works often have no author name; use the statement of
    // responsibility ("disunting oleh …") instead.
    if (authors.isEmpty) {
      final sor = kids(mods, 'note').where((n) => n.getAttribute('type') == 'statement of responsibility').firstOrNull;
      final t = text(sor);
      if (t != null) authors.add(t.replaceAll(RegExp(r'\.$'), ''));
    }

    final langCode = mods.findAllElements('languageTerm').where((l) => l.getAttribute('type') == 'code').firstOrNull?.innerText.trim();
    final ddc = kids(mods, 'classification').where((c) => c.getAttribute('authority') == 'ddc').firstOrNull;

    if (title == null) return null;
    return BookMetadata(
      source: 'library_of_congress',
      sources: const ['library_of_congress'],
      isbn: isbn13,
      title: title,
      subtitle: subtitle,
      authors: authors,
      publisher: publisher,
      publicationYear: year,
      edition: edition,
      language: langCode == null ? null : (_iso6392to1[langCode] ?? langCode),
      description: text(kids(mods, 'abstract').firstOrNull),
      callNumber: text(ddc),
    );
  }

  static const _iso6392to1 = {
    'may': 'ms', 'msa': 'ms', 'eng': 'en', 'ind': 'id', 'chi': 'zh', 'zho': 'zh', 'tam': 'ta',
    'ara': 'ar', 'jpn': 'ja', 'kor': 'ko', 'tha': 'th', 'fre': 'fr', 'ger': 'de', 'spa': 'es',
  };

  /// Trims catalogue punctuation (trailing " /", " :", ",", ";") and blanks.
  static String? _clean(String? s) {
    if (s == null) return null;
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'[\s/:;,=]+$'), '').trim();
    return t.isEmpty ? null : t;
  }

  static int? _year(String? date) {
    final m = RegExp(r'(1[0-9]{3}|2[0-9]{3})').firstMatch(date ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }
}
