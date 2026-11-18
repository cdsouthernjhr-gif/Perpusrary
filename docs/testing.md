# Ujian

## Database (migration, RLS, sync, concurrency)

Ujian ditulis dalam SQL biasa (tanpa pgTAP) supaya boleh dijalankan pada
PostgreSQL 15+ biasa **atau** stack Supabase tempatan.

```bash
# PostgreSQL biasa (menggunakan stub platform Supabase)
PGHOST=localhost PGPORT=5432 PGUSER=postgres ./scripts/db_test.sh

# Stack Supabase tempatan (supabase start) – tanpa stub
SKIP_STUB=1 SKIP_RESET=1 PGHOST=127.0.0.1 PGPORT=54322 PGUSER=postgres \
  PGPASSWORD=postgres TEST_DB=postgres ./scripts/db_test.sh
```

> Nota: jangan guna `supabase test db` – ia menjangka fail pgTAP.

Apa yang dijalankan:

| Langkah | Fail |
|---|---|
| Migration ×2 (bukti idempoten) | `supabase/migrations/*.sql` |
| Audit skema statik | `00_schema_audit.sql` – RLS di semua jadual, tiada grant anon, DEFINER hanya dalam `private` dengan `search_path`, setiap GRANT disokong polisi, `library_id` NOT NULL & tidak boleh diubah |
| Pengasingan & peranan | `10_rls_isolation.sql` – 7 ujian wajib + kes tambahan |
| Sync | `20_sync.sql` – idempotensi, retry, konflik versi, barcode bertembung, payload berniat jahat, pull berhalaman, tombstone |
| Jemputan & Storage | `30_invitations_storage.sql` |
| Kontrak payload katalog (Fasa 4) | `50_catalog_payload_contract.sql` – payload tepat seperti dijana `CatalogDao` diterima `sync_push` (null, perpuluhan, tarikh ISO, FIFO, update penuh oleh staff, padam lembut) |
| Backup & restore (Fasa 7) | `80_backup_restore.sql` – editor / admin lain / perpustakaan lain / baris `library_id` asing / format / hubungan / barcode berulang ditolak; pemulihan judul, status, kategori yang dipadam keras (id sama), tombstone dibuang, pergerakan "Restore", idempoten, `delete_missing`, perpustakaan tidak aktif |
| Keputusan sync (Fasa 6) | `70_sync_results.sql` – `server_row` pada penolakan, tiada kebocoran antara perpustakaan, teras push tidak didedahkan |
| Inventori (Fasa 5) | `60_inventory.sql` – jadual kes pariti dengan aplikasi (jenis & kuantiti pergerakan), rujukan/catatan, jumlah lejar = stok semasa, Viewer/perpustakaan lain |
| Pengguna & perpustakaan (Fasa 3) | `40_members_libraries.sql` – e-mel profil, senarai ahli ikut peranan, tukar peranan/nyahaktif, `create_library` + jemputan admin |
| Concurrency sebenar (2–3 sambungan serentak) | `scripts/db_concurrency_test.sh` – barcode sama serentak, operation_id sama serentak, 2×25 naskhah serentak, **C4: dua pengguna menyunting naskhah sama dari versi sama → satu diterima, satu konflik, satu pergerakan** |

Setiap fail ujian berjalan dalam transaksi yang di-*rollback*; ujian
concurrency membersihkan datanya sendiri. Pengguna disimulasikan tepat seperti
PostgREST: `SET ROLE authenticated` + `request.jwt.claims`.

## Flutter

```bash
flutter analyze
flutter test
```

| Fail | Liputan |
|---|---|
| `test/unit/app_config_test.dart` | penolakan kunci service_role / sb_secret, URL |
| `test/unit/validators_test.dart` | validator selari dengan CHECK DB |
| `test/unit/router_redirect_test.dart` | logik redirect auth / pemulihan kata laluan |
| `test/unit/app_failure_test.dart` | pemetaan ralat → mesej BM |
| `test/widget/login_screen_test.dart` | validasi borang, panggilan signIn, paparan ralat |
| `test/unit/local_dao_test.dart` | Drift: cache perpustakaan, pemadaman data dibatalkan, barcode unik per perpustakaan, statistik, kiraan sync, wipe |
| `test/unit/library_context_test.dart` | pengesahan semula keahlian, tukar perpustakaan, pulih pilihan terakhir, akses ditarik, luar talian, pengguna lain pada peranti sama, Super Admin |
| `test/unit/sync_indicator_test.dart` | keutamaan penunjuk sync |
| `test/widget/library_switcher_dashboard_test.dart` | switcher → dashboard A → tukar → dashboard B (tiada data A), pengawal laluan, butang Super Admin, penunjuk sync |

| `test/unit/isbn_barcode_test.dart` | normalisasi/checksum ISBN-10/13, penukaran, validasi barcode, penjana barcode |
| `test/unit/book_metadata_test.dart` | Google Books → Open Library, tiada hasil/luar talian/ralat pelayan, hanya ISBN dihantar |
| `test/unit/catalog_dao_test.dart` | transaksi buku+naskhah, outbox FIFO & penggabungan, barcode/nombor perolehan unik per perpustakaan, rollback, pendua, carian, jana barcode, pengasingan perpustakaan |
| `test/unit/label_pdf_test.dart` | PDF label berbilang halaman |
| `test/widget/catalog_flow_test.dart` | daftar buku → naskhah dijana, amaran pendua, Viewer tanpa butang, pengimbas keyboard-wedge, barcode pendua ditolak, buku A tidak muncul di B, **semua skrin utama tanpa limpahan pada telefon 360dp** |

| `test/unit/db_migration_test.dart` | migrasi Drift v1 → v2 pada fail sebenar, data sedia ada kekal |
| `test/unit/inventory_test.dart` | pariti `copyMovement` dengan trigger pelayan, pergerakan sementara + `operation_id`, pukal semua-atau-tiada, laporan inventori, sejarah, semakan stok (berterusan selepas "restart") |
| `test/widget/inventory_flow_test.dart` | tukar status pukal melalui pengimbas keyboard-wedge, semakan stok hujung-ke-hujung, Viewer tanpa tindakan, log aktiviti (dalam/luar talian), skrin inventori pada 360dp |

| `test/unit/sync_transport_test.dart` | backoff, klasifikasi ralat (rangkaian vs akses ditolak), pemeta baris pelayan, JSON push/pull |
| `test/widget/sync_center_test.dart` | Sync sekarang, luar talian, konflik + guna versi pelayan, Staf tidak boleh *override* katalog, barcode pendua → jana baharu, sync automatik apabila perpustakaan dipilih, 360dp |

| `test/unit/xlsx_test.dart` | penulis/pembaca XLSX: jenis data, freeze, autofilter, lebar, preamble, fail gaya Excel (shared strings, tarikh), fail bukan xlsx |
| `test/unit/excel_export_test.dart` | 8 worksheet, kiraan, ringkasan, tiada data perpustakaan lain, aktiviti luar talian |
| `test/unit/excel_import_test.dart` | templat diimport semula, ralat setiap baris (tajuk, ISBN, tahun, barcode, status, kos, tarikh mustahil, rak, pendua dalam fail/perpustakaan), `library_id` diabaikan, mod pendua, cipta/tidak cipta kategori & lokasi, jana barcode |
| `test/widget/phase7_test.dart` | import hujung-ke-hujung + sync, baris tidak sah dikecualikan, Staf tiada import, eksport 8 worksheet, backup → tolak fail perpustakaan lain → restore dengan pengesahan kod + backup pre-restore, backup admin sahaja, 360dp |

### Fasa 8 – keselamatan, UI, prestasi, peranti

| Ujian | Kandungan | Keputusan |
|---|---|---|
| `supabase/tests/database/90_rls_matrix.sql` | **400 probe**: 8 peranan × 50 kes (13 jadual × SELECT/INSERT/UPDATE/DELETE) dibandingkan dengan matriks akses; ujian mutasi mengesahkan ia mengesan perubahan | ✅ |
| `scripts/security_audit.sh` | rahsia/JWT service_role dalam repo & APK, fail env/keystore ter-commit, manifest (backup, cleartext), DEFINER di luar `private`, APK release tidak *debuggable*; ujian mutasi dengan kunci palsu | ✅ (repo, APK debug & release) |
| `test/widget/ui_smoke_test.dart` | **27 skrin × 4 konfigurasi**: telefon 360dp teks 1.5× dan 2.0×, mod gelap, tablet landskap 1280×800 – gagal pada sebarang limpahan | ✅ |
| `scripts/perf_test.sh` | pelayan, 2 × 12,000 judul / 20,000 naskhah, RLS aktif | ✅ (lihat progress.md) |
| `test/perf/client_perf_test.dart` (`PERF=1`) | klien Drift, 12k judul / 20k naskhah | ✅ (lihat progress.md) |
| `integration_test/device_offline_flow_test.dart` | pada peranti: daftar luar talian → mulakan semula aplikasi → data kekal → sync | ⚠️ **belum dijalankan** (tiada peranti/KVM) |

Jalankan ujian peranti dengan telefon disambungkan:
`flutter test integration_test/device_offline_flow_test.dart`

### Pengesahan fail Excel dengan alat luaran

```bash
XLSX_OUT=/tmp/x/sample.xlsx flutter test test/unit/xlsx_export_file_test.dart
python3 -c "import openpyxl; wb=openpyxl.load_workbook('/tmp/x/sample_export.xlsx'); print(wb.sheetnames)"
soffice --headless --convert-to 'xlsx:Calc MS Excel 2007 XML' --outdir /tmp/lo /tmp/x/sample_template.xlsx
XLSX_IN=/tmp/lo/sample_template.xlsx flutter test test/unit/xlsx_export_file_test.dart
```

### Integrasi sync dengan PostgreSQL sebenar

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres ./scripts/sync_integration_test.sh
```

Dua "peranti" (dua pangkalan data Drift) menyegerak melalui `sync_push` /
`sync_pull` sebenar sebagai pengguna `authenticated` (RLS penuh), melalui
`test/integration/helpers/pg_sync_remote.dart`. 12 senario: pull awal &
pengasingan, daftar luar talian → sync, peranti kedua, **respons hilang
selepas pelayan commit (tiada pendua)**, **barcode sama pada dua peranti
luar talian**, **konflik + kedua-dua penyelesaian**, rebase suntingan semasa
penghantaran, ahli dibuang, perubahan *forbidden* dipulihkan, tombstone,
pull berkursor, **aplikasi ditutup & dibuka semula sebelum sync**.
Ditambah `test/integration/backup_restore_pg_test.dart` (5 senario): backup
admin (laluan folder, checksum, kiraan), restore + backup pre-restore + peranti
menerima data dipulihkan, perlindungan antara perpustakaan (klien, Storage RLS,
pelayan), Staf tidak boleh backup/restore, fail diubah dikesan oleh checksum.
Ujian ini dilangkau oleh `flutter test` biasa jika `SLM_PG_PORT` tiada.

> Widget test yang menggunakan Drift mesti memanggil `finish(tester)` di hujung
> (nyahlekap pokok widget + tutup DB dalam `runAsync`), jika tidak ujian tergantung.

`test/integration/` – disediakan untuk Fasa 8 (perlu peranti/emulator Android).

## Yang BELUM diuji

- Aplikasi pada peranti Android sebenar / emulator (tiada Android SDK dalam
  persekitaran CI ini).
- Migration pada projek Supabase *hosted* sebenar (diuji pada PostgreSQL 16 +
  stub; perlu disahkan sekali pada Supabase – lihat progress.md).
- Aliran e-mel Supabase Auth sebenar (pengesahan, reset kata laluan).
