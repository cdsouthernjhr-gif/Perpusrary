# RLS & Keselamatan

## Model kebenaran

Sumber kebenaran tunggal: **`public.library_members`** (peranan + status aktif)
dan **`public.system_admins`**. `user_metadata` / `app_metadata` dalam JWT
**tidak pernah** dibaca untuk kebenaran (diuji: JWT dengan
`user_metadata.role = "super_admin"` tidak memberi apa-apa akses).

Kedudukan peranan: `viewer(1) < staff(2) < editor(3) < library_admin(4)`.
Super Admin bukan peranan perpustakaan – ia rekod dalam `system_admins` yang
hanya boleh ditambah melalui SQL oleh pemilik database.

### Pembantu (schema `private`, tidak didedahkan oleh Data API)

| Fungsi | Pulangan |
|---|---|
| `private.readable_library_ids()` | perpustakaan dengan keahlian aktif (mana-mana peranan); Super Admin = semua |
| `private.writable_library_ids(min_role)` | keahlian aktif ≥ `min_role` **dan** perpustakaan aktif |
| `private.library_ids_with_role(min_role, require_active)` | asas kepada kedua-duanya |
| `private.is_super_admin()` | boolean |

Polisi menggunakan bentuk `library_id in (select private.…())` supaya
fungsi dinilai **sekali setiap kenyataan** (subplan), bukan setiap baris.

### Mengapa SECURITY DEFINER digunakan (dan bagaimana ia dikawal)

Pembantu keahlian perlu membaca `library_members` tanpa terkena RLS
`library_members` sendiri (rekursi). Ini satu-satunya kegunaan SECURITY
DEFINER dalam laluan RLS. Kawalan:

- Dalam schema `private` (tidak didedahkan; `USAGE` diberi kepada
  `authenticated` hanya supaya polisi boleh memanggilnya).
- `REVOKE ALL ... FROM public, anon`; `EXECUTE` hanya kepada `authenticated`.
- `SET search_path = ''` dan nama layak penuh.
- Identiti hanya daripada `auth.uid()`; tiada parameter pengguna yang boleh
  menukar identiti.
- Fungsi trigger audit (`tg_audit`, `tg_copy_stock_movement`,
  `tg_sync_tombstone`, `tg_handle_new_user`) juga DEFINER supaya log tidak
  boleh dipalsukan – client tiada GRANT tulis pada `stock_movements` /
  `sync_tombstones`, dan untuk `activity_logs` hanya boleh menambah
  `entity_type = 'app_event'` atas nama sendiri.
- `accept_invitation` → `private.accept_invitation_impl` (DEFINER) menyemak
  e-mel daripada `auth.users` (bukan metadata), status, tarikh luput.
- Ujian `00_schema_audit.sql` menggagalkan build jika ada SECURITY DEFINER di
  luar `private` atau tanpa `search_path`.

Semua RPC awam (`sync_push`, `sync_pull`, `my_libraries`, `library_dashboard`,
`find_possible_duplicate_books`) ialah **SECURITY INVOKER** – RLS tetap
berkuat kuasa di dalamnya.

## Matriks akses

| Jadual | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| libraries | ahli | Super Admin | library_admin (kod/status: Super Admin) | Super Admin |
| system_admins | diri sendiri | – | – | – |
| user_profiles | diri + pengguna sepustaka | diri | diri | – |
| library_members | diri; library_admin | library_admin | library_admin | Super Admin (guna `removed`) |
| library_invitations | library_admin; penerima (e-mel JWT, pending) | library_admin | library_admin | library_admin |
| device_registry | diri; library_admin sepustaka | diri | diri | diri |
| categories, locations | ahli | editor | editor | library_admin |
| books | ahli | staff | editor | library_admin |
| book_copies | ahli | staff | staff (barcode/book/padam: editor) | library_admin |
| stock_movements | ahli | (trigger) | ✗ append-only | ✗ |
| activity_logs | ahli | app_event diri sahaja | ✗ | ✗ |
| sync_operations | diri; library_admin | staff (diri) | diri | ✗ |
| sync_tombstones | ahli | (trigger) | ✗ | ✗ |
| import_jobs | editor | editor | editor | library_admin |
| backup_records | library_admin | library_admin | library_admin | library_admin |

Semua tulisan memerlukan perpustakaan **aktif** (kecuali Super Admin).
`anon` tiada sebarang GRANT. Setiap GRANT kepada `authenticated` disokong
polisi (diuji automatik).

## Storage

- `library-assets` (logo, kulit buku) dan `library-backups`: **kedua-duanya
  peribadi**. Muat turun hanya melalui *signed URL* jangka pendek.
- Laluan objek: `<library_id>/...`. Polisi menghurai segmen pertama dengan
  `private.try_uuid()` (nama rosak → ditolak, bukan ralat).
- Backup: hanya Library Admin perpustakaan tersebut / Super Admin.
- `backup_records.file_path` dikekang CHECK supaya bermula dengan `library_id`.

## Aplikasi

- APK hanya mengandungi URL + **anon/publishable key**. `AppConfig` enggan
  bermula jika diberi kunci `service_role` / `sb_secret_…`.
- Sesi disimpan dalam `flutter_secure_storage` (Android Keystore); aliran PKCE.
  Tiada kata laluan disimpan.
- `android:allowBackup="false"`.
- Pilihan perpustakaan terakhir disimpan tempatan sebagai *petunjuk* sahaja;
  akses disahkan semula dengan `my_libraries()` setiap sesi (Fasa 3).

## Ujian yang mengesahkan

`supabase/tests/database/10_rls_isolation.sql` merangkumi 7 ujian wajib
spesifikasi ([1]–[7]) serta kes tambahan (IDOR, FK komposit, pengguna dibuang,
anon, eskalasi peranan, Library Admin terakhir, perpustakaan tidak aktif).
`30_invitations_storage.sql` menguji fail backup perpustakaan lain.
