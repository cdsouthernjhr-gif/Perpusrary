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

> Widget test yang menggunakan Drift mesti memanggil `finish(tester)` di hujung
> (nyahlekap pokok widget + tutup DB dalam `runAsync`), jika tidak ujian tergantung.

`test/integration/` – disediakan untuk Fasa 8 (perlu peranti/emulator Android).

## Yang BELUM diuji

- Aplikasi pada peranti Android sebenar / emulator (tiada Android SDK dalam
  persekitaran CI ini).
- Migration pada projek Supabase *hosted* sebenar (diuji pada PostgreSQL 16 +
  stub; perlu disahkan sekali pada Supabase – lihat progress.md).
- Aliran e-mel Supabase Auth sebenar (pengesahan, reset kata laluan).
