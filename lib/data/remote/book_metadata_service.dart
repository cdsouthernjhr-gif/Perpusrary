import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
    this.language,
    this.description,
    this.coverUrl,
    this.isbn,
  });

  final String source; // google_books | open_library
  final String? title;
  final String? subtitle;
  final List<String> authors;
  final String? publisher;
  final int? publicationYear;
  final String? language;
  final String? description;
  final String? coverUrl;
  final String? isbn;

  String? get author => authors.isEmpty ? null : authors.join(', ');
}

/// Looks an ISBN up in Google Books, then Open Library. Only the ISBN is sent
/// (no user or library data). Returns null when nothing is found or the
/// network is unavailable — callers then fall back to manual entry.
class BookMetadataService {
  BookMetadataService({http.Client? client, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<BookMetadata?> lookup(String rawIsbn) async {
    final isbn = Isbn.canonical(rawIsbn);
    if (isbn == null || !Isbn.matchesDbFormat(isbn)) return null;
    return await _tryGoogle(isbn) ?? await _tryOpenLibrary(isbn);
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final res = await _client.get(uri, headers: {'Accept': 'application/json'}).timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map<String, dynamic> ? body : null;
    } on Exception {
      return null; // offline / timeout / bad JSON → manual entry
    }
  }

  Future<BookMetadata?> _tryGoogle(String isbn) async {
    final json = await _getJson(Uri.https('www.googleapis.com', '/books/v1/volumes', {'q': 'isbn:$isbn'}));
    final items = json?['items'];
    if (items is! List || items.isEmpty) return null;
    final info = (items.first as Map<String, dynamic>)['volumeInfo'];
    if (info is! Map<String, dynamic>) return null;
    final images = info['imageLinks'];
    String? cover = images is Map ? (images['thumbnail'] ?? images['smallThumbnail']) as String? : null;
    if (cover != null && cover.startsWith('http://')) cover = cover.replaceFirst('http://', 'https://');
    return BookMetadata(
      source: 'google_books',
      isbn: isbn,
      title: info['title'] as String?,
      subtitle: info['subtitle'] as String?,
      authors: ((info['authors'] as List?) ?? const []).whereType<String>().toList(),
      publisher: info['publisher'] as String?,
      publicationYear: _year(info['publishedDate'] as String?),
      language: info['language'] as String?,
      description: info['description'] as String?,
      coverUrl: cover,
    );
  }

  Future<BookMetadata?> _tryOpenLibrary(String isbn) async {
    final json = await _getJson(Uri.https('openlibrary.org', '/api/books', {
      'bibkeys': 'ISBN:$isbn',
      'format': 'json',
      'jscmd': 'data',
    }));
    final data = json?['ISBN:$isbn'];
    if (data is! Map<String, dynamic>) return null;
    List<String> names(Object? list) =>
        ((list as List?) ?? const []).whereType<Map<String, dynamic>>().map((m) => m['name']).whereType<String>().toList();
    final cover = data['cover'];
    return BookMetadata(
      source: 'open_library',
      isbn: isbn,
      title: data['title'] as String?,
      subtitle: data['subtitle'] as String?,
      authors: names(data['authors']),
      publisher: names(data['publishers']).firstOrNull,
      publicationYear: _year(data['publish_date'] as String?),
      coverUrl: cover is Map ? (cover['medium'] ?? cover['small']) as String? : null,
    );
  }

  static int? _year(String? date) {
    final m = RegExp(r'(1[0-9]{3}|2[0-9]{3})').firstMatch(date ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }
}
