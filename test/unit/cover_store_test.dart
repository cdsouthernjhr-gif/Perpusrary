import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/features/books/application/cover_store.dart';

const lib = '11111111-1111-4111-8111-111111111111';
final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);

class FakeRemote implements CoverRemote {
  final objects = <String, Uint8List>{};
  final uploads = <String>[];
  bool online = true;

  @override
  Future<void> upload(String objectPath, Uint8List bytes, String mimeType) async {
    if (!online) throw const SocketException('offline');
    uploads.add('$objectPath $mimeType');
    objects[objectPath] = bytes;
  }

  @override
  Future<Uint8List?> download(String objectPath) async {
    if (!online) throw const SocketException('offline');
    return objects[objectPath];
  }
}

void main() {
  late Directory tmp;
  late FakeRemote remote;
  late CoverStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('covers');
    remote = FakeRemote();
    store = CoverStore(root: () async => tmp, remote: remote);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('image type is detected from bytes; other files are refused', () async {
    expect(CoverImageType.sniff(jpeg), CoverImageType.jpeg);
    expect(CoverImageType.sniff(png), CoverImageType.png);
    expect(CoverImageType.sniff(Uint8List.fromList('RIFF0000WEBPVP8 '.codeUnits)), CoverImageType.webp);
    expect(CoverImageType.sniff(Uint8List.fromList('%PDF-1.7'.codeUnits)), isNull);
    expect(() => store.add(lib, Uint8List.fromList('<svg>'.codeUnits)), throwsA(isA<CoverException>()));
    expect(() => store.add(lib, Uint8List(CoverStore.maxBytes + 1)..setAll(0, jpeg)), throwsA(isA<CoverException>()));
  });

  test('only well-formed storage refs are accepted (no path traversal)', () {
    const ok = 'storage:$lib/covers/22222222-2222-4222-8222-222222222222.jpg';
    expect(CoverRef.objectPath(ok), '$lib/covers/22222222-2222-4222-8222-222222222222.jpg');
    expect(CoverRef.libraryOf(ok), lib);
    for (final bad in [
      'storage:../../shared_prefs/x.jpg',
      'storage:$lib/covers/../../x.jpg',
      'storage:$lib/backups/22222222-2222-4222-8222-222222222222.jpg',
      'storage:$lib/covers/22222222-2222-4222-8222-222222222222.exe',
      'https://example.com/a.jpg',
      'storage:not-a-uuid/covers/22222222-2222-4222-8222-222222222222.jpg',
    ]) {
      expect(CoverRef.objectPath(bad), isNull, reason: bad);
    }
    expect(() => store.add('../etc', jpeg), throwsA(isA<CoverException>()));
  });

  test('photo is kept locally, uploaded only after markPending, once', () async {
    final ref = await store.add(lib, png);
    expect(ref, matches(RegExp(r'^storage:' + lib + r'/covers/[0-9a-f-]{36}\.png$')));
    expect(await store.localFile(ref), isNotNull);
    expect(await store.uploadPending(lib), 0, reason: 'not saved with a book yet');

    await store.markPending(ref);
    expect(await store.pendingCount(lib), 1);
    expect(await store.uploadPending(lib), 1);
    expect(remote.uploads.single, '${CoverRef.objectPath(ref)} image/png');
    expect(await store.pendingCount(lib), 0);
    expect(await store.uploadPending(lib), 0);
  });

  test('offline: stays pending and is uploaded on the next attempt', () async {
    final ref = await store.add(lib, jpeg);
    await store.markPending(ref);
    remote.online = false;
    expect(await store.uploadPending(lib), 0);
    expect(await store.pendingCount(lib), 1);
    remote.online = true;
    expect(await store.uploadPending(lib), 1);
  });

  test('another device downloads the cover once and keeps a local copy', () async {
    final path = '$lib/covers/33333333-3333-4333-8333-333333333333.jpg';
    remote.objects[path] = jpeg;
    final f = await store.resolve('storage:$path');
    expect(await f!.readAsBytes(), jpeg);
    remote.online = false;
    expect(await store.resolve('storage:$path'), isNotNull, reason: 'served from the local copy offline');
    expect(await store.resolve('storage:$lib/covers/44444444-4444-4444-8444-444444444444.jpg'), isNull);
    expect(await store.resolve('storage:../x.jpg'), isNull);
  });
}
