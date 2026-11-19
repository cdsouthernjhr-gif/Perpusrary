import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/remote/supabase/supabase_providers.dart';

/// Book cover photos taken/picked on the device.
///
/// * books.cover_image_path holds either an https URL (from an ISBN
///   catalogue) or `storage:<library_id>/covers/<uuid>.<ext>` — an object in
///   the PRIVATE Storage bucket `library-assets`. Storage RLS (0700) lets
///   members read and staff+ upload under their own library's folder only.
/// * Offline first: the photo is written to the app's private files at once
///   and marked "pending"; it is uploaded when the device is online (after
///   saving the book and after every successful sync). Other devices download
///   it with their own session and keep a local copy.
abstract final class CoverRef {
  static const scheme = 'storage:';
  static const bucket = 'library-assets';

  static bool isStorage(String? ref) => ref != null && ref.startsWith(scheme);

  /// Strict shape: the value comes from a synced, user-writable column, so
  /// anything else (e.g. "../") is refused before it can touch the
  /// file system.
  static final _pattern =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/covers/'
          r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$');

  /// Object path inside the bucket, or null when [ref] is not a valid
  /// storage ref.
  static String? objectPath(String? ref) {
    if (!isStorage(ref)) return null;
    final p = ref!.substring(scheme.length);
    return _pattern.hasMatch(p) ? p : null;
  }

  /// Library that owns the object (first path segment).
  static String? libraryOf(String? ref) => objectPath(ref)?.split('/').first;
}

/// Supported image types, detected from the bytes (not the file name).
enum CoverImageType {
  jpeg('jpg', 'image/jpeg'),
  png('png', 'image/png'),
  webp('webp', 'image/webp');

  const CoverImageType(this.extension, this.mimeType);
  final String extension;
  final String mimeType;

  static CoverImageType? sniff(Uint8List b) {
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return jpeg;
    if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return png;
    if (b.length > 12 &&
        String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      return webp;
    }
    return null;
  }
}

class CoverException implements Exception {
  const CoverException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Storage access (with the signed-in user's session; RLS applies).
abstract interface class CoverRemote {
  /// Uploads; an object that already exists counts as success.
  Future<void> upload(String objectPath, Uint8List bytes, String mimeType);

  /// Bytes, or null when the object does not exist (yet).
  Future<Uint8List?> download(String objectPath);
}

class SupabaseCoverRemote implements CoverRemote {
  SupabaseCoverRemote(this._db);
  final SupabaseClient _db;

  @override
  Future<void> upload(String objectPath, Uint8List bytes, String mimeType) async {
    try {
      await _db.storage
          .from(CoverRef.bucket)
          .uploadBinary(objectPath, bytes, fileOptions: FileOptions(contentType: mimeType, upsert: false));
    } on StorageException catch (e) {
      // Already uploaded earlier (e.g. retry after a lost response).
      if (e.statusCode == '409' || e.message.toLowerCase().contains('exists')) return;
      rethrow;
    }
  }

  @override
  Future<Uint8List?> download(String objectPath) async {
    try {
      return await _db.storage.from(CoverRef.bucket).download(objectPath);
    } on StorageException catch (e) {
      if (e.statusCode == '404' || e.statusCode == '400') return null; // not uploaded yet / not visible
      rethrow;
    }
  }
}

/// Local files under `<app files>/covers/<object path>`; a sibling
/// `<file>.pending` marks files still to upload.
class CoverStore {
  CoverStore({required Future<Directory> Function() root, required CoverRemote remote, Uuid? uuid})
      : _root = root, // ignore: prefer_initializing_formals
        _remote = remote, // ignore: prefer_initializing_formals
        _uuid = uuid ?? const Uuid();

  final Future<Directory> Function() _root;
  final CoverRemote _remote;
  final Uuid _uuid;

  static final _uuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// Max stored size; the bucket limit is 5 MB.
  static const maxBytes = 4 * 1024 * 1024;

  Future<File> _file(String objectPath) async => File('${(await _root()).path}/covers/$objectPath');

  /// Stores a new photo for [libraryId] (not yet marked for upload) and
  /// returns its cover ref. Throws [CoverException] for bad input.
  Future<String> add(String libraryId, Uint8List bytes) async {
    final type = CoverImageType.sniff(bytes);
    if (type == null) throw const CoverException('Format gambar tidak disokong. Gunakan JPG, PNG atau WebP.');
    if (bytes.length > maxBytes) throw const CoverException('Gambar terlalu besar (had 4 MB).');
    final ref = '${CoverRef.scheme}$libraryId/covers/${_uuid.v4()}.${type.extension}';
    final objectPath = CoverRef.objectPath(ref);
    if (objectPath == null) throw const CoverException('Perpustakaan tidak sah.');
    final f = await _file(objectPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return ref;
  }

  /// Marks a stored photo for upload (call after the book is saved).
  Future<void> markPending(String ref) async {
    final p = CoverRef.objectPath(ref);
    if (p == null) return;
    final f = await _file(p);
    if (await f.exists()) await File('${f.path}.pending').writeAsString('');
  }

  /// Local copy if present (no network).
  Future<File?> localFile(String ref) async {
    final p = CoverRef.objectPath(ref);
    if (p == null) return null;
    final f = await _file(p);
    return await f.exists() ? f : null;
  }

  /// Local copy, downloading it first when needed. Null when unavailable
  /// (offline, not uploaded yet, no access).
  Future<File?> resolve(String ref) async {
    final local = await localFile(ref);
    if (local != null) return local;
    final p = CoverRef.objectPath(ref);
    if (p == null) return null;
    try {
      final bytes = await _remote.download(p);
      if (bytes == null || CoverImageType.sniff(bytes) == null) return null;
      final f = await _file(p);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      return f;
    } on Object {
      return null;
    }
  }

  /// Uploads pending photos of [libraryId]. Returns how many were uploaded;
  /// stops at the first failure (retried after the next sync).
  Future<int> uploadPending(String libraryId) async {
    if (!_uuidPattern.hasMatch(libraryId)) return 0;
    final dir = Directory('${(await _root()).path}/covers/$libraryId/covers');
    if (!await dir.exists()) return 0;
    var n = 0;
    final markers = await dir.list().where((e) => e is File && e.path.endsWith('.pending')).cast<File>().toList();
    for (final marker in markers) {
      final img = File(marker.path.substring(0, marker.path.length - '.pending'.length));
      if (!await img.exists()) {
        await marker.delete();
        continue;
      }
      final bytes = await img.readAsBytes();
      final type = CoverImageType.sniff(bytes);
      if (type == null) {
        await marker.delete();
        continue;
      }
      try {
        await _remote.upload('$libraryId/covers/${img.uri.pathSegments.last}', bytes, type.mimeType);
      } on Object {
        break;
      }
      await marker.delete();
      n++;
    }
    return n;
  }

  Future<int> pendingCount(String libraryId) async {
    if (!_uuidPattern.hasMatch(libraryId)) return 0;
    final dir = Directory('${(await _root()).path}/covers/$libraryId/covers');
    if (!await dir.exists()) return 0;
    return dir.list().where((e) => e.path.endsWith('.pending')).length;
  }
}

/// Camera / gallery boundary (testable).
abstract interface class CoverPicker {
  /// Resized, compressed image bytes, or null when cancelled.
  Future<Uint8List?> pick({required bool camera});
}

class ImagePickerCoverPicker implements CoverPicker {
  final _picker = ImagePicker();

  @override
  Future<Uint8List?> pick({required bool camera}) async {
    final x = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1600,
      imageQuality: 80,
      requestFullMetadata: false, // no location/EXIF needed
    );
    return x?.readAsBytes();
  }
}

final coverRemoteProvider = Provider<CoverRemote>((ref) => SupabaseCoverRemote(ref.watch(supabaseClientProvider)));

final coverStoreProvider = Provider<CoverStore>(
  (ref) => CoverStore(root: getApplicationSupportDirectory, remote: ref.watch(coverRemoteProvider)),
);

final coverPickerProvider = Provider<CoverPicker>((ref) => ImagePickerCoverPicker());

/// Local file for a storage cover ref (downloads when missing). autoDispose
/// so a failed download is retried the next time the cover is shown.
final coverFileProvider = FutureProvider.autoDispose.family<File?, String>(
  (ref, coverRef) => ref.watch(coverStoreProvider).resolve(coverRef),
);
