import 'package:drift/drift.dart' show Uint8List;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// File pick/save boundary (Android Storage Access Framework via
/// file_picker). Abstracted so screens can be tested without platform UI.
abstract interface class FileIo {
  /// Returns (file name, bytes) or null when the user cancels.
  Future<(String, Uint8List)?> pick({required List<String> extensions});

  /// Lets the user choose where to save. Returns false when cancelled.
  Future<bool> save(String fileName, Uint8List bytes, {required String extension});
}

class FilePickerFileIo implements FileIo {
  @override
  Future<(String, Uint8List)?> pick({required List<String> extensions}) async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: extensions);
    if (f == null) return null;
    return (f.name, await f.readAsBytes());
  }

  @override
  Future<bool> save(String fileName, Uint8List bytes, {required String extension}) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
    return uri != null;
  }
}

final fileIoProvider = Provider<FileIo>((ref) => FilePickerFileIo());
