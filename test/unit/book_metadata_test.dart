import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartlibrary_manager/core/utils/isbn.dart';
import 'package:smartlibrary_manager/data/remote/book_metadata_service.dart';

http.Response json(Object o) => http.Response.bytes(utf8.encode(jsonEncode(o)), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
http.Response xml(String s) =>
    http.Response.bytes(utf8.encode(s), 200, headers: {'content-type': 'application/xml; charset=utf-8'});

const _locEmpty = '<?xml version="1.0"?><zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/">'
    '<zs:version>1.1</zs:version><zs:numberOfRecords>0</zs:numberOfRecords></zs:searchRetrieveResponse>';

// Trimmed real LoC SRU/MODS answer for 9789834923129 (DBP, 2020).
const _locSejarahMelaka = '''<?xml version="1.0"?>
<zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/"><zs:version>1.1</zs:version><zs:numberOfRecords>1</zs:numberOfRecords><zs:records><zs:record><zs:recordSchema>mods</zs:recordSchema><zs:recordPacking>xml</zs:recordPacking><zs:recordData><mods xmlns="http://www.loc.gov/mods/v3" version="3.8">
  <titleInfo><title>Sejarah Melaka</title></titleInfo>
  <titleInfo type="alternative"><title>Melaka</title></titleInfo>
  <name type="personal" usage="primary">
    <namePart>Buyong bin Adil,</namePart>
    <namePart type="termsOfAddress">Haji.</namePart>
    <role><roleTerm type="text">author</roleTerm></role>
  </name>
  <name type="personal"><namePart>Someone Else,</namePart><role><roleTerm type="text">translator</roleTerm></role></name>
  <originInfo><place><placeTerm type="code" authority="marccountry">my</placeTerm></place>
    <dateIssued encoding="marc">2020</dateIssued><edition>Edisi semakan</edition></originInfo>
  <originInfo eventType="publication"><place><placeTerm type="text">Kuala Lumpur :</placeTerm></place>
    <agent><namePart>Dewan Bahasa dan Pustaka,</namePart><role><roleTerm>publisher</roleTerm></role></agent>
    <dateIssued>2020.</dateIssued></originInfo>
  <language><languageTerm authority="iso639-2b" type="code">may</languageTerm></language>
  <abstract type="Summary">History of Malacca Kingdom and its kings.</abstract>
  <classification authority="lcc">DS596.5 .B89 2020</classification>
  <classification authority="ddc">959.51</classification>
  <identifier type="isbn">9789834923129</identifier>
</mods></zs:recordData></zs:record></zs:records></zs:searchRetrieveResponse>''';

void main() {
  final requests = <Uri>[];
  setUp(requests.clear);

  /// Routes each catalogue host to a handler; unspecified hosts answer "not found".
  BookMetadataService service({
    http.Response Function(Uri)? google,
    http.Response Function(Uri)? openLibrary,
    http.Response Function(Uri)? loc,
  }) =>
      BookMetadataService(client: MockClient((req) async {
        requests.add(req.url);
        switch (req.url.host) {
          case 'www.googleapis.com':
            return google?.call(req.url) ?? json({'totalItems': 0});
          case 'openlibrary.org':
            return openLibrary?.call(req.url) ?? json({});
          case 'lx2.loc.gov':
            return loc?.call(req.url) ?? xml(_locEmpty);
        }
        return http.Response('', 404);
      }));

  test('ISBN-13 → ISBN-10 conversion (978 only)', () {
    expect(Isbn.to10('9780306406157'), '0306406152');
    expect(Isbn.to10('9789834923129'), '9834923120');
    expect(Isbn.to10(Isbn.to13('080442957X')!), '080442957X'); // check digit X round-trip
    expect(Isbn.to10('9791032300824'), isNull); // 979 has no ISBN-10
    expect(Isbn.to10('9780306406158'), isNull); // bad checksum
  });

  test('all three catalogues are asked, with both ISBN forms; only the ISBN is sent', () async {
    final svc = service();
    final r = await svc.search('978-0-306-40615-7');
    expect(r.found, isFalse);
    expect(r.unreachable, isEmpty);
    final hosts = requests.map((u) => u.host).toSet();
    expect(hosts, {'www.googleapis.com', 'openlibrary.org', 'lx2.loc.gov'});
    // Google: ISBN-13 then ISBN-10.
    expect(requests.where((u) => u.host == 'www.googleapis.com').map((u) => u.queryParameters['q']),
        ['isbn:9780306406157', 'isbn:0306406152']);
    expect(requests.firstWhere((u) => u.host == 'openlibrary.org').queryParameters['bibkeys'],
        'ISBN:9780306406157,ISBN:0306406152');
    expect(requests.firstWhere((u) => u.host == 'lx2.loc.gov').queryParameters['query'],
        'bath.isbn=9780306406157 or bath.isbn=0306406152');
    for (final u in requests) {
      final sent = u.queryParameters.values.join(' ');
      expect(sent, isNot(contains('@')));
    }
  });

  test('Google Books is the main source; other catalogues only fill gaps', () async {
    final svc = service(
      google: (u) => json({
        'items': [
          {
            'volumeInfo': {
              'title': 'Wrong volume',
              'industryIdentifiers': [
                {'type': 'ISBN_13', 'identifier': '9781111111111'}
              ],
            }
          },
          {
            'volumeInfo': {
              'title': 'Hikayat Hang Tuah',
              'authors': ['Kassim Ahmad'],
              'publishedDate': '1997-05-01',
              'language': 'ms',
              'industryIdentifiers': [
                {'type': 'ISBN_10', 'identifier': '0306406152'}
              ],
              'imageLinks': {'thumbnail': 'http://books.google.com/x.jpg'},
            }
          }
        ]
      }),
      openLibrary: (u) => json({
        'ISBN:0306406152': {
          'title': 'Hikayat Hang Tuah (OL)',
          'publishers': [
            {'name': 'Dewan Bahasa dan Pustaka'}
          ],
          'classifications': {
            'dewey_decimal_class': ['899.2303']
          },
        }
      }),
    );
    final m = (await svc.search('0-306-40615-2')).book!;
    expect(m.source, 'google_books');
    expect(m.title, 'Hikayat Hang Tuah', reason: 'volume carrying the ISBN is preferred');
    expect(m.author, 'Kassim Ahmad');
    expect(m.publisher, 'Dewan Bahasa dan Pustaka', reason: 'filled from Open Library');
    expect(m.callNumber, '899.2303');
    expect(m.publicationYear, 1997);
    expect(m.coverUrl, startsWith('https://'));
    expect(m.isbn, '9780306406157');
    expect(m.sources, ['google_books', 'open_library']);
  });

  test('Malaysian title found only in the Library of Congress', () async {
    final svc = service(loc: (_) => xml(_locSejarahMelaka));
    final m = (await svc.search('9789834923129')).book!;
    expect(m.source, 'library_of_congress');
    expect(m.title, 'Sejarah Melaka');
    expect(m.author, 'Buyong bin Adil', reason: 'translator and honorific excluded, trailing comma trimmed');
    expect(m.publisher, 'Dewan Bahasa dan Pustaka');
    expect(m.publicationYear, 2020);
    expect(m.edition, 'Edisi semakan');
    expect(m.language, 'ms');
    expect(m.callNumber, '959.51', reason: 'DDC, not LCC');
    expect(m.description, startsWith('History of Malacca'));
  });

  test('LoC statement of responsibility is used when no author is named', () async {
    final rec = _locSejarahMelaka
        .replaceFirst(RegExp(r'<name type="personal" usage="primary">.*?</name>', dotAll: true), '')
        .replaceFirst(RegExp(r'<name type="personal"><namePart>Someone.*?</name>', dotAll: true), '')
        .replaceFirst('<abstract', '<note type="statement of responsibility">disunting oleh Ahmad Ali.</note><abstract');
    final m = (await service(loc: (_) => xml(rec)).search('9789834923129')).book!;
    expect(m.author, 'disunting oleh Ahmad Ali');
  });

  test('Open Library publisher listed as author is dropped', () async {
    final svc = service(
      openLibrary: (u) => json({
        'ISBN:9789834916732': {
          'title': 'Bahasa-bahasa utama dunia',
          'authors': [
            {'name': 'V. A. Pogadaev'},
            {'name': 'Dewan Bahasa dan Pustaka'}
          ],
          'publishers': [
            {'name': 'Dewan Bahasa dan Pustaka, Malaysia'}
          ],
        }
      }),
    );
    expect((await svc.search('9789834916732')).book!.author, 'V. A. Pogadaev');
  });

  test('Open Library is used when Google has nothing', () async {
    final svc = service(
      openLibrary: (u) => json({
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
      }),
    );
    final m = (await svc.search('9780306406157')).book!;
    expect(m.source, 'open_library');
    expect(m.publisher, 'Plenum');
    expect(m.publicationYear, 1990);
  });

  test('rate limit / server error / offline are reported, not treated as "not found"', () async {
    final svc = service(
      google: (_) => http.Response('quota', 429),
      openLibrary: (_) => http.Response('down', 503),
      loc: (_) => xml(_locSejarahMelaka),
    );
    final r = await svc.search('9789834923129');
    expect(r.book!.title, 'Sejarah Melaka', reason: 'one failing catalogue does not hide the others');
    expect(r.unreachable, ['google_books', 'open_library']);

    final offline = BookMetadataService(client: MockClient((_) async => throw const SocketException('offline')));
    final o = await offline.search('9789834923129');
    expect(o.found, isFalse);
    expect(o.unreachable.length, 3);
  });

  test('not found everywhere returns null (manual entry allowed)', () async {
    expect(await service().lookup('9780306406157'), isNull);
    expect(await BookMetadataService(client: MockClient((_) async => http.Response('', 404))).lookup('9780306406157'),
        isNull);
  });

  test('invalid ISBN format makes no request', () async {
    final svc = service();
    expect(await svc.lookup('abc'), isNull);
    expect(requests, isEmpty);
  });

  test('optional Google API key is sent only to Google', () async {
    final svc = BookMetadataService(
      googleApiKey: 'test-key',
      client: MockClient((req) async {
        requests.add(req.url);
        return req.url.host == 'lx2.loc.gov' ? xml(_locEmpty) : json({});
      }),
    );
    await svc.search('9780306406157');
    expect(requests.where((u) => u.host == 'www.googleapis.com').every((u) => u.queryParameters['key'] == 'test-key'),
        isTrue);
    expect(requests.where((u) => u.host != 'www.googleapis.com').any((u) => u.queryParameters.containsKey('key')),
        isFalse);
  });
}
