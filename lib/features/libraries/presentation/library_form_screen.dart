import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/validators.dart';
import '../../../data/providers.dart';
import '../../../shared/models/library_models.dart';
import '../../../shared/widgets/auth_scaffold.dart';
import '../../../shared/widgets/common_widgets.dart';
import '../application/library_context.dart';

/// Create (Super Admin) or edit (Library Admin / Super Admin) a library.
class LibraryFormScreen extends ConsumerStatefulWidget {
  const LibraryFormScreen({super.key, this.libraryId});

  /// null = create
  final String? libraryId;

  @override
  ConsumerState<LibraryFormScreen> createState() => _LibraryFormScreenState();
}

class _LibraryFormScreenState extends ConsumerState<LibraryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _org = TextEditingController();
  final _address = TextEditingController();
  final _contact = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _adminEmail = TextEditingController();
  DateTime? _established;
  String _status = 'active';
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.libraryId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await ref.read(libraryRepositoryProvider).getDetails(widget.libraryId!);
      _name.text = d.name;
      _code.text = d.code;
      _org.text = d.organizationName ?? '';
      _address.text = d.address ?? '';
      _contact.text = d.contactPerson ?? '';
      _phone.text = d.phone ?? '';
      _email.text = d.email ?? '';
      _established = d.establishedOn;
      _status = d.status;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _code, _org, _address, _contact, _phone, _email, _adminEmail]) {
      c.dispose();
    }
    super.dispose();
  }

  LibraryDetails get _details => LibraryDetails(
        name: _name.text.trim(),
        code: _code.text.trim().toUpperCase(),
        organizationName: _org.text,
        address: _address.text,
        contactPerson: _contact.text,
        phone: _phone.text,
        email: _email.text,
        establishedOn: _established,
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = ref.read(libraryRepositoryProvider);
    final ok = await runWithFeedback(context, () async {
      if (_isEdit) {
        await repo.update(widget.libraryId!, _details);
      } else {
        await repo.create(_details, firstAdminEmail: _adminEmail.text.trim().isEmpty ? null : _adminEmail.text);
      }
      await ref.read(libraryContextProvider.notifier).refresh();
    }, success: _isEdit ? 'Maklumat perpustakaan dikemas kini.' : 'Perpustakaan didaftarkan.');
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) context.pop();
  }

  Future<void> _toggleStatus(bool active) async {
    final ok = await runWithFeedback(context, () async {
      await ref.read(libraryRepositoryProvider).setStatus(widget.libraryId!, active: active);
      await ref.read(libraryContextProvider.notifier).refresh();
    }, success: active ? 'Perpustakaan diaktifkan.' : 'Perpustakaan dinyahaktifkan.');
    if (ok && mounted) setState(() => _status = active ? 'active' : 'inactive');
  }

  @override
  Widget build(BuildContext context) {
    final isSuper = ref.watch(isSuperAdminProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Perpustakaan' : 'Tambah Perpustakaan')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 12)],
                  _field(_name, 'Nama perpustakaan *', validator: (v) => Validators.required(v, field: 'Nama')),
                  _field(
                    _code,
                    'Kod perpustakaan *',
                    enabled: !_isEdit || isSuper,
                    caps: TextCapitalization.characters,
                    validator: (v) => Validators.libraryCode(v?.toUpperCase()),
                    helper: 'Unik dalam sistem. Hanya Super Admin boleh menukarnya.',
                  ),
                  _field(_org, 'Nama organisasi'),
                  _field(_address, 'Alamat', maxLines: 3),
                  _field(_contact, 'Pegawai bertanggungjawab'),
                  _field(_phone, 'Telefon', keyboard: TextInputType.phone),
                  _field(_email, 'E-mel',
                      keyboard: TextInputType.emailAddress,
                      validator: (v) => (v == null || v.trim().isEmpty) ? null : Validators.email(v)),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event),
                    title: const Text('Tarikh diwujudkan'),
                    subtitle: Text(_established == null ? '-' : DateFormat('d MMM yyyy').format(_established!)),
                    trailing: const Icon(Icons.edit_calendar),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime(1800),
                        lastDate: DateTime.now(),
                        initialDate: _established ?? DateTime.now(),
                      );
                      if (d != null) setState(() => _established = d);
                    },
                  ),
                  if (!_isEdit)
                    _field(_adminEmail, 'E-mel Pentadbir Perpustakaan pertama (jemputan)',
                        keyboard: TextInputType.emailAddress,
                        validator: (v) => (v == null || v.trim().isEmpty) ? null : Validators.email(v)),
                  if (_isEdit && isSuper)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Perpustakaan aktif'),
                      subtitle: const Text('Perpustakaan tidak aktif hanya boleh dibaca.'),
                      value: _status == 'active',
                      onChanged: _toggleStatus,
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Menyimpan…' : 'Simpan'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? Function(String?)? validator,
    bool enabled = true,
    int maxLines = 1,
    TextInputType? keyboard,
    TextCapitalization caps = TextCapitalization.sentences,
    String? helper,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: c,
          enabled: enabled,
          maxLines: maxLines,
          keyboardType: keyboard,
          textCapitalization: caps,
          decoration: InputDecoration(labelText: label, helperText: helper),
          validator: validator,
        ),
      );
}
