import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router/routes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/barcode.dart';
import '../../../core/utils/isbn.dart';
import '../../../core/utils/validators.dart';
import '../../../data/local/database/app_database.dart';
import '../../../data/remote/book_metadata_service.dart';
import '../../../data/providers.dart';
import '../../../shared/models/catalog_models.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../../barcode/presentation/scan_field.dart';
import '../../barcode/presentation/scanner_screen.dart';
import '../../libraries/application/library_context.dart';
import '../application/catalog_providers.dart';
import '../application/cover_store.dart';
import 'catalog_widgets.dart';

/// Register a new title (+ first copies) or edit an existing one.
class BookFormScreen extends ConsumerStatefulWidget {
  const BookFormScreen({super.key, this.bookId});
  final String? bookId;

  @override
  ConsumerState<BookFormScreen> createState() => _BookFormScreenState();
}

class _BookFormScreenState extends ConsumerState<BookFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _isbn = TextEditingController();
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _author = TextEditingController();
  final _publisher = TextEditingController();
  final _year = TextEditingController();
  final _edition = TextEditingController();
  final _language = TextEditingController();
  final _callNumber = TextEditingController();
  final _description = TextEditingController();
  final _barcode = TextEditingController();
  final _reference = TextEditingController();
  String? _categoryId;
  String? _coverUrl;
  bool _pickingCover = false;
  String _metadataSource = 'manual';
  String? _lookupMessage;
  bool _lookingUp = false;
  bool _saving = false;
  bool _loaded = false;

  // First copies (create mode)
  int _copyCount = 1;
  bool _autoBarcode = true;
  String? _locationId;
  AcquisitionSource? _source = AcquisitionSource.purchase;

  bool get _isEdit => widget.bookId != null;

  @override
  void dispose() {
    for (final c in [_isbn, _title, _subtitle, _author, _publisher, _year, _edition, _language, _callNumber,
        _description, _barcode, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fillFrom(LocalBook b) {
    _isbn.text = b.isbn ?? '';
    _title.text = b.title;
    _subtitle.text = b.subtitle ?? '';
    _author.text = b.author ?? '';
    _publisher.text = b.publisher ?? '';
    _year.text = b.publicationYear?.toString() ?? '';
    _edition.text = b.edition ?? '';
    _language.text = b.language ?? '';
    _callNumber.text = b.callNumber ?? '';
    _description.text = b.description ?? '';
    _categoryId = b.categoryId;
    _coverUrl = b.coverImagePath;
    _metadataSource = b.metadataSource ?? 'manual';
    _loaded = true;
  }

  Future<void> _lookup() async {
    final isbn = Isbn.canonical(_isbn.text);
    if (isbn == null || Isbn.validate(isbn) != null) {
      setState(() => _lookupMessage = 'Masukkan ISBN yang sah dahulu.');
      return;
    }
    setState(() {
      _lookingUp = true;
      _lookupMessage = null;
    });
    final result = await ref.read(bookMetadataServiceProvider).search(isbn);
    if (!mounted) return;
    final m = result.book;
    String unreachableNote() => result.unreachable.isEmpty
        ? ''
        : ' (${result.unreachable.map(BookMetadata.labelOf).join(', ')} tidak dapat dihubungi)';
    setState(() {
      _lookingUp = false;
      _isbn.text = isbn;
      if (m == null) {
        _lookupMessage = result.unreachable.length == 3
            ? 'Tiada sambungan ke pangkalan data buku. Semak internet, atau isi secara manual.'
            : 'ISBN ini tiada dalam Google Books, Open Library atau Library of Congress'
                '${unreachableNote()}. Sila isi secara manual.';
        return;
      }
      // Fill only empty fields so typed data is never overwritten.
      // Values are cut to the database column limits.
      void fill(TextEditingController c, String? v, int max) {
        if (c.text.trim().isEmpty && v != null) c.text = v.length > max ? v.substring(0, max).trimRight() : v;
      }

      fill(_title, m.title, 500);
      fill(_subtitle, m.subtitle, 500);
      fill(_author, m.author, 500);
      fill(_publisher, m.publisher, 300);
      fill(_year, m.publicationYear?.toString(), 4);
      fill(_edition, m.edition, 100);
      fill(_language, m.language, 50);
      fill(_callNumber, m.callNumber, 60);
      fill(_description, m.description, 5000);
      _coverUrl ??= m.coverUrl;
      _metadataSource = m.source;
      _lookupMessage = 'Maklumat diisi daripada ${m.sources.map(BookMetadata.labelOf).join(' + ')}'
          '${unreachableNote()}. Sila semak sebelum simpan.';
    });
  }

  BookInput get _input => BookInput(
        title: _title.text,
        subtitle: _subtitle.text,
        isbn: Isbn.canonical(_isbn.text),
        author: _author.text,
        publisher: _publisher.text,
        publicationYear: int.tryParse(_year.text.trim()),
        edition: _edition.text,
        language: _language.text,
        description: _description.text,
        categoryId: _categoryId,
        callNumber: _callNumber.text,
        coverImagePath: _coverUrl,
        metadataSource: _metadataSource,
      );

  /// Returns true to continue saving.
  Future<bool> _confirmDuplicates(CatalogActions actions) async {
    final dups = await actions.possibleDuplicates(_input, excludeId: widget.bookId);
    if (dups.isEmpty || !mounted) return true;
    const reasonLabel = {
      'isbn': 'ISBN sama',
      'title': 'tajuk serupa',
      'author': 'pengarang serupa',
      'publisher': 'penerbit sama',
      'year': 'tahun sama',
    };
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        key: const Key('duplicates.dialog'),
        icon: const Icon(Icons.content_copy),
        title: const Text('Kemungkinan rekod pendua'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Judul berikut sudah ada. Jika ini edisi lain, anda boleh tetap menyimpan rekod baharu. '
                  'Jika sama, tambah naskhah pada rekod sedia ada.'),
              const SizedBox(height: 12),
              for (final d in dups.take(5))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.book.title),
                  subtitle: Text([
                    if (d.book.author != null) d.book.author!,
                    if (d.book.edition != null) 'Edisi ${d.book.edition}',
                    if (d.book.publicationYear != null) '${d.book.publicationYear}',
                    d.reasons.map((r) => reasonLabel[r] ?? r).join(', '),
                  ].join(' • ')),
                  trailing: TextButton(
                    onPressed: () => Navigator.pop(c, 'open:${d.book.id}'),
                    child: const Text('Buka'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Batal')),
          FilledButton(
            key: const Key('duplicates.saveAnyway'),
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('Simpan sebagai rekod baharu'),
          ),
        ],
      ),
    );
    if (choice != null && choice.startsWith('open:') && mounted) {
      context.pushReplacement(Routes.book(choice.substring(5)));
      return false;
    }
    return choice == 'save';
  }

  Future<void> _pickCover({required bool camera}) async {
    final lib = ref.read(activeLibraryProvider);
    if (lib == null) return;
    setState(() => _pickingCover = true);
    try {
      final bytes = await ref.read(coverPickerProvider).pick(camera: camera);
      if (bytes == null) return; // cancelled
      final coverRef = await ref.read(coverStoreProvider).add(lib.id, bytes);
      if (mounted) setState(() => _coverUrl = coverRef);
    } on CoverException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      if (mounted) {
        showSnack(
            context,
            camera
                ? 'Kamera tidak dapat dibuka. Benarkan akses kamera dalam Tetapan Android, atau pilih dari galeri.'
                : 'Gambar tidak dapat dibuka: $e',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _pickingCover = false);
    }
  }

  /// After the book is saved locally: queue the photo for upload and try now.
  Future<void> _commitCover() async {
    final c = _coverUrl;
    final lib = ref.read(activeLibraryProvider);
    if (c == null || lib == null || !CoverRef.isStorage(c)) return;
    final store = ref.read(coverStoreProvider);
    await store.markPending(c);
    if (ref.read(isOnlineProvider)) {
      unawaited(store.uploadPending(lib.id).catchError((Object _) => 0));
    }
  }

  Widget _coverSection() {
    final hasCover = _coverUrl != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookCover(key: const Key('book.cover'), url: _coverUrl, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Gambar kulit buku', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('book.cover.camera'),
                      onPressed: _pickingCover ? null : () => _pickCover(camera: true),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Kamera'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('book.cover.gallery'),
                      onPressed: _pickingCover ? null : () => _pickCover(camera: false),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Galeri'),
                    ),
                    if (hasCover)
                      TextButton.icon(
                        key: const Key('book.cover.remove'),
                        onPressed: _pickingCover ? null : () => setState(() => _coverUrl = null),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Buang'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final actions = ref.read(catalogActionsProvider);
    if (!await _confirmDuplicates(actions)) return;
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await actions.updateBook(widget.bookId!, _input);
        await _commitCover();
        if (mounted) {
          showSnack(context, 'Buku dikemas kini.');
          context.pop();
        }
        return;
      }
      final copies = <CopyInput>[];
      for (var i = 0; i < _copyCount; i++) {
        final barcode = _autoBarcode ? await actions.generateBarcode() : _barcode.text.trim();
        copies.add(CopyInput(
          barcode: barcode,
          locationId: _locationId,
          acquisitionSource: _source,
          acquisitionDate: DateTime.now(),
        ));
      }
      final id = await actions.createBook(_input,
          copies: copies, meta: MovementMeta(referenceNumber: _reference.text, remarks: 'Pendaftaran buku'));
      await _commitCover();
      if (mounted) {
        showSnack(context, 'Buku didaftarkan dengan ${copies.length} naskhah. Akan disegerakkan apabila dalam talian.');
        context.pushReplacement(Routes.book(id));
      }
    } catch (e) {
      final f = AppFailure.from(e);
      if (!mounted) return;
      if (f.code == 'duplicate_barcode') {
        await showDuplicateBarcodeDialog(context, ref, f, _barcode.text.trim(),
            onGenerateNew: () => setState(() => _autoBarcode = true));
      } else {
        showSnack(context, f.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isEdit && !_loaded) {
      final book = ref.watch(bookProvider(widget.bookId!));
      return book.when(
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorView(error: e)),
        data: (b) {
          if (b == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Buku tidak dijumpai.')));
          WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _fillFrom(b)));
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        },
      );
    }

    final categories = ref.watch(categoriesProvider).value ?? const [];
    final locations = ref.watch(locationsProvider).value ?? const [];
    final isbnWarning = Isbn.checksumWarning(_isbn.text);

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Buku' : 'Daftar Buku')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ScanField(
              key: const Key('book.isbn'),
              controller: _isbn,
              label: 'ISBN',
              mode: ScanMode.isbn,
              helperText: isbnWarning ?? 'Imbas, taip, atau guna pengimbas barcode. Tidak wajib.',
              validator: Isbn.validate,
              onScanned: (_) => _lookup(),
              onSubmitted: (_) => _lookup(),
              extraSuffix: IconButton(
                tooltip: 'Cari maklumat buku',
                icon: _lookingUp
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore),
                onPressed: _lookingUp ? null : _lookup,
              ),
            ),
            if (_lookupMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_lookupMessage!),
              ),
            const SizedBox(height: 12),
            _coverSection(),
            _f(_title, 'Tajuk *', key: 'book.title', validator: (v) => Validators.required(v, field: 'Tajuk')),
            _f(_subtitle, 'Subjudul'),
            _f(_author, 'Pengarang'),
            _f(_publisher, 'Penerbit'),
            Row(
              children: [
                Expanded(
                  child: _f(_year, 'Tahun terbit', keyboard: TextInputType.number, validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final y = int.tryParse(v.trim());
                    return (y == null || y < 1000 || y > DateTime.now().year + 1) ? 'Tahun tidak sah.' : null;
                  }),
                ),
                const SizedBox(width: 12),
                Expanded(child: _f(_edition, 'Edisi')),
              ],
            ),
            Row(
              children: [
                Expanded(child: _f(_language, 'Bahasa')),
                const SizedBox(width: 12),
                Expanded(child: _f(_callNumber, 'Nombor panggilan')),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String?>(
                isExpanded: true,
                initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
                decoration: const InputDecoration(labelText: 'Kategori'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— Tiada —')),
                  for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
            _f(_description, 'Keterangan', maxLines: 4),
            if (!_isEdit) ...[
              const Divider(height: 32),
              Text('Naskhah fizikal', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Bilangan naskhah'),
                  const Spacer(),
                  IconButton(
                    onPressed: _copyCount > 0 ? () => setState(() => _copyCount--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$_copyCount', key: const Key('book.copyCount'), style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    onPressed: _copyCount < 50
                        ? () => setState(() {
                              _copyCount++;
                              if (_copyCount > 1) _autoBarcode = true;
                            })
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              if (_copyCount > 0) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Jana barcode secara automatik'),
                  subtitle: Text(_copyCount > 1
                      ? 'Wajib untuk lebih daripada satu naskhah (tambah barcode sedia ada satu persatu kemudian).'
                      : 'Matikan untuk mengimbas barcode sedia ada pada buku.'),
                  value: _autoBarcode,
                  onChanged: _copyCount > 1 ? null : (v) => setState(() => _autoBarcode = v),
                ),
                if (!_autoBarcode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ScanField(
                      controller: _barcode,
                      label: 'Barcode naskhah *',
                      mode: ScanMode.copyBarcode,
                      validator: CopyBarcode.validate,
                    ),
                  ),
                DropdownButtonFormField<String?>(
                isExpanded: true,
                  initialValue: _locationId,
                  decoration: const InputDecoration(labelText: 'Lokasi rak'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— Belum ditetapkan —')),
                    for (final l in locations) DropdownMenuItem(value: l.id, child: Text(locationLabel(l), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _locationId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<AcquisitionSource?>(
                isExpanded: true,
                  initialValue: _source,
                  decoration: const InputDecoration(labelText: 'Sumber perolehan'),
                  items: [
                    for (final s in AcquisitionSource.values) DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                  onChanged: (v) => setState(() => _source = v),
                ),
                const SizedBox(height: 12),
                _f(_reference, 'No. rujukan (cth. pesanan belian)'),
              ],
            ],
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('book.save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Menyimpan…' : 'Simpan'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _f(TextEditingController c, String label,
          {String? key, String? Function(String?)? validator, int maxLines = 1, TextInputType? keyboard}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: key == null ? null : Key(key),
          controller: c,
          maxLines: maxLines,
          keyboardType: keyboard,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label),
          validator: validator,
        ),
      );
}
