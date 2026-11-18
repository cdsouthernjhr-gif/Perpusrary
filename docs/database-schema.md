# Skema Database

Migration: `supabase/migrations/` (dijalankan mengikut nama fail; semuanya
idempoten – `IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP ... IF EXISTS`).

| Fail | Kandungan |
|---|---|
| `…0100_foundation.sql` | extension (`pgcrypto`, `pg_trgm` dalam schema `extensions`), schema `private`, trigger generik |
| `…0200_core_tables.sql` | `libraries`, `system_admins`, `user_profiles`, `library_members`, `library_invitations`, `device_registry` |
| `…0300_catalog_tables.sql` | `categories`, `locations`, `books`, `book_copies`, `stock_movements`, `activity_logs`, `sync_operations`, `sync_tombstones`, `import_jobs`, `backup_records` |
| `…0400_functions_and_triggers.sql` | pembantu keahlian (RLS), trigger audit/stok/tombstone/pengawal |
| `…0500_rls_policies.sql` | GRANT + RLS (SELECT/INSERT/UPDATE/DELETE berasingan) |
| `…0600_rpc_functions.sql` | `my_libraries`, `accept_invitation`, `sync_push`, `sync_pull`, `library_dashboard`, `find_possible_duplicate_books` |
| `…0700_storage.sql` | bucket peribadi + polisi `storage.objects` |
| `…1100_phase7_backup_restore.sql` | RPC `restore_library_backup` (+ `private.restore_rows`, `private.clear_tombstones`); pengawal trigger `libraries`/`book_copies` kini hanya untuk peranan API (`private.is_api_user()`) supaya penyelenggaraan oleh pemilik DB tidak disekat |
| `…1000_phase6_sync_results.sql` | `sync_push` jadi pembalut: teras dipindah ke `private.sync_push_core` (idempoten); keputusan `rejected/failed` kini menyertakan `server_row` semasa (tertakluk RLS) |
| `…0900_phase5_inventory.sql` | `created_at` default `clock_timestamp()` untuk `stock_movements`/`activity_logs` (dan `deleted_at` tombstone) – susunan tepat dalam satu transaksi; indeks jenis pergerakan |
| `…0800_phase3_members_libraries.sql` | `user_profiles.email` (cermin `auth.users`, tidak boleh diubah client – grant peringkat lajur), `library_invitations.library_name`, RPC `library_member_list`, `create_library`; pembetulan polisi SELECT `libraries` (Super Admin `INSERT … RETURNING`) dan audit semasa pemadaman seluruh perpustakaan |

## Jadual

Semua kunci utama UUID. Medan **tebal** dikawal pelayan (nilai client diabaikan).

### Teras
- **libraries** – `id, name, code (unik sistem, A-Z0-9_-), address, organization_name, logo_path, contact_person, phone, email, established_on, status(active|inactive), `**`version, sync_xid, created_by`**`, created_at, updated_at`.
  Hanya Super Admin boleh tukar `code`/`status`.
- **system_admins** – `user_id`. Diurus melalui SQL sahaja (tiada polisi tulis).
- **user_profiles** – `id → auth.users, full_name, phone, avatar_path`. Dicipta automatik oleh trigger pada `auth.users`.
- **library_members** – `library_id, user_id, role(library_admin|editor|staff|viewer), membership_status(active|suspended|removed), invited_by, joined_at`. `UNIQUE(library_id, user_id)`. Tidak boleh tinggal tanpa Library Admin aktif.
- **library_invitations** – `library_id, email, role, status(pending|accepted|revoked|expired), invited_by(**dipaksa**), expires_at, accepted_by, accepted_at`. Satu jemputan *pending* setiap (library, email).
- **device_registry** – `id (UUID peranti), user_id, device_name, platform, app_version, last_seen_at, status`.

### Katalog & inventori
- **categories** – `library_id, name (unik per library, aktif), code, description, deleted_at` + version/sync_xid.
- **locations** – `library_id, building, room, section, rack_code, shelf_code, description, deleted_at`. Unik pada gabungan slot.
- **books** (judul/edisi) – `library_id, title, subtitle, isbn (10/13 digit, ternormal, TIDAK unik), author, publisher, publication_year, edition, language, description, category_id, call_number, cover_image_path, metadata_source, deleted_at`.
- **book_copies** (naskhah fizikal) – `library_id, book_id, barcode (ASCII boleh cetak ≤64, Code 128), accession_number (unik jika diisi), condition, location_id, acquisition_date/source/cost, status(available|in_processing|damaged|lost|inactive), remarks, deleted_at`. **`UNIQUE(library_id, barcode)`** – barcode naskhah yang dipadam lembut kekal terpelihara.
- **stock_movements** (append-only, ditulis trigger) – `copy_id, movement_type(acquisition|status_change|relocation|adjustment|removal|restoration), quantity(-1..1), from/to_status, from/to_location_id, reference_number, remarks, created_by, sync_xid`.

### Audit, sync, import, backup
- **activity_logs** (append-only) – `library_id (NULL = peristiwa sistem), user_id, action, entity_type, entity_id, details JSONB (medan berubah lama/baru), device_id`.
- **sync_operations** – `operation_id UNIQUE` (kunci idempotensi), `entity_type, entity_id, operation_type, base_version, payload, sync_status(processing|applied|conflict|rejected|failed), error_code, error_message, result, processed_at`.
- **sync_tombstones** – rekod hard delete supaya peranti boleh membuang salinan tempatan.
- **import_jobs** – `file_name, duplicate_mode(skip|update|insert_new), status, total/successful/failed_rows, error_summary`.
- **backup_records** – `file_path (mesti bermula dengan "<library_id>/"), backup_type, status, file_size, checksum, record_counts`.

## Integriti antara perpustakaan

Foreign key komposit memastikan hubungan hanya dalam perpustakaan yang sama:

| Anak | FK | Induk |
|---|---|---|
| books | `(library_id, category_id)` | categories `(library_id, id)` – `ON DELETE SET NULL (category_id)` |
| book_copies | `(library_id, book_id)` | books |
| book_copies | `(library_id, location_id)` | locations – `ON DELETE SET NULL (location_id)` |
| stock_movements | `(library_id, copy_id)` | book_copies |

Trigger `tg_05_library_id_immutable` pada **setiap** jadual milik perpustakaan
menghalang `library_id` diubah (walaupun pengguna ahli kedua-dua perpustakaan).

## Trigger utama

| Trigger | Jadual | Fungsi |
|---|---|---|
| `tg_10_versioning` | libraries, categories, locations, books, book_copies | `version` +1, `sync_xid`, timestamp |
| `tg_20_created_by` | sama | `created_by = auth.uid()` |
| `tg_90_audit` | sama + library_members | tulis `activity_logs` (perbezaan medan) |
| `tg_50_stock_movement` | book_copies | tulis `stock_movements` dalam transaksi yang sama |
| `tg_95_tombstone` | categories, locations, books, book_copies | `sync_tombstones` pada hard delete |
| `tg_15_guard` | libraries / book_copies | kod/status hanya Super Admin; barcode/book/padam perlukan Editor |
| `tg_20_guard` | library_members | `user_id` tetap; jaga Library Admin terakhir |
| `tg_00_append_only` | stock_movements, activity_logs, sync_tombstones | tolak UPDATE |

## Indeks

Indeks `library_id` pada semua jadual; `(library_id, sync_xid)` untuk pull;
trigram GIN pada `books.title/author` untuk carian & pengesanan pendua;
`(library_id, isbn)`, `(library_id, status)` separa untuk naskhah aktif.
