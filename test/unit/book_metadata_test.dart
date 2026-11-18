import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartlibrary_manager/data/remote/book_metadata_service.dart';

void main() {
  final requests = <Uri>[];
  http.Response json(Object o) => http.Response.bytes(utf8.encode(jsonEncode(o)), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  setUp(requests.clear);

  test('Google Books result is used first and only the ISBN is sent', () async {
    final svc = BookMetadataService(client: MockClient((req) async {
      requests.add(req.url);
      return json({
        'items': [
          {
            'volumeInfo': {
              'title': 'Hikayat Hang Tuah',
              'authors': ['Kassim Ahmad'],
              'publisher': 'DBP',
              'publishedDate': '1997-05-01',
              'language': 'ms',
              'imageLinks': {'thumbnail': 'http://books.google.com/x.jpg'},
            }
          }
        ]
      });
    }));
    final m = await svc.lookup('0-306-40615-2');
    expect(m!.source, 'google_books');
    expect(m.title, 'Hikayat Hang Tuah');
    expect(m.author, 'Kassim Ahmad');
    expect(m.publicationYear, 1997);
    expect(m.coverUrl, startsWith('https://'));
    expect(requests.single.queryParameters['q'], 'isbn:9780306406157');
  });

  test('falls back to Open Library', () async {
    final svc = BookMetadataService(client: MockClient((req) async {
      requests.add(req.url);
      if (req.url.host == 'www.googleapis.com') return json({'totalItems': 0});
      return json({
        'ISBN:9780306406157': {
          'title': 'The Physics of Waves',
          'authors': [
            {'name': 'A. Author'}
          ],
          'publishers': [
            {'name': 'Plenum'}
          ],
          'publish_date': 'March 1990',
          'cover': {'medium': 'https://covers.openlibrary.org/b/id/1-M.jpg'},
        }
      });
    }));
    final m = await svc.lookup('9780306406157');
    expect(m!.source, 'open_library');
    expect(m.publisher, 'Plenum');
    expect(m.publicationYear, 1990);
    expect(requests.length, 2);
  });

  test('not found / offline / server error return null (manual entry allowed)', () async {
    expect(await BookMetadataService(client: MockClient((_) async => json({}))).lookup('9780306406157'), isNull);
    expect(
        await BookMetadataService(client: MockClient((_) async => throw const SocketException('offline')))
            .lookup('9780306406157'),
        isNull);
    expect(await BookMetadataService(client: MockClient((_) async => http.Response('x', 500))).lookup('9780306406157'),
        isNull);
  });

  test('invalid ISBN format makes no request', () async {
    final svc = BookMetadataService(client: MockClient((req) async {
      requests.add(req.url);
      return json({});
    }));
    expect(await svc.lookup('abc'), isNull);
    expect(requests, isEmpty);
  });
}
