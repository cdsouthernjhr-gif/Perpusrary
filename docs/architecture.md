# Seni Bina

## Gambaran keseluruhan

```
┌──────────────── Peranti Android (setiap pengguna) ────────────────┐
│ Flutter UI (Material 3, material_ui)                               │
│   └─ features/* (presentation → application → data)                │
│ Riverpod (state/DI)   GoRouter (navigasi + auth redirect)          │
│ Repositories ──┬── Drift/SQLite (katalog tempatan + sync queue)    │  ← Fasa 3/6
│                └── Supabase client (Auth, PostgREST, Storage)      │
└───────────────────────────────┬────────────────────────────────────┘
                                │ HTTPS + JWT (anon/publishable key)
┌───────────────────────────────▼──────── Supabase (1 projek) ───────┐
│ Auth (GoTrue)  →  JWT sub = auth.uid()                              │
│ PostgREST: schema public sahaja                                     │
│   Jadual (RLS wajib)  +  RPC SECURITY INVOKER (sync_push/pull, ...) │
│ schema private: pembantu keahlian & trigger (tidak didedahkan)      │
│ Storage: library-assets, library-backups (peribadi, folder=library) │
└─────────────────────────────────────────────────────────────────────┘
```

## Prinsip

1. **Pengasingan data di pelayan.** Setiap rekod milik perpustakaan ada
   `library_id`; akses ditentukan oleh `library_members` melalui RLS.
   Penapis di Flutter hanya untuk UX, bukan keselamatan.
2. **Pelayan ialah sumber kebenaran.** `version`, `sync_xid`, `created_by`,
   `stock_movements` dan `activity_logs` dijana oleh trigger pelayan; nilai
   daripada client diabaikan.
3. **Offline-first** (Fasa 6): semua penulisan pergi ke SQLite dahulu dan
   baris gilir sync; operasi hanya dianggap selesai selepas pelayan mengesahkan.
4. **Idempotensi**: setiap operasi ada `operation_id` UUID unik.
5. **Clean Architecture ringan**: `presentation` (widget) → `application`
   (controller/state) → `data` (repository interface + implementasi
   Supabase/Drift). UI bergantung pada interface supaya boleh diuji dengan mock.

## Struktur `lib/`

| Folder | Isi |
|---|---|
| `app/` | `app.dart`, `router/` (GoRouter + logik redirect tulen), `theme/` |
| `core/config` | `AppConfig` – baca `--dart-define`, **tolak kunci service_role** |
| `core/security` | Storan sesi dalam Android Keystore (`flutter_secure_storage`) |
| `core/errors` | `AppFailure` – peta ralat Postgres/Auth → mesej BM |
| `core/utils` | Validator (selari dengan CHECK di database) |
| `data/remote/supabase` | Provider klien Supabase |
| `data/repositories` | Interface + implementasi repository |
| `data/local` | Drift database & DAO (Fasa 3) |
| `features/<modul>` | `presentation/`, `application/` setiap modul |
| `shared/widgets` | Widget dikongsi |

## Database tempatan (Drift) – Fasa 3

`lib/data/local/database/` – skema v1:

| Jadual | Kegunaan |
|---|---|
| `local_libraries` | cache `my_libraries()` + `verified_at` |
| `key_values` | `device_id`, `owner_user_id`, `active_library_id` |
| `local_categories`, `local_locations`, `local_books`, `local_book_copies` | cermin katalog (`server_version`, `sync_state`, `deleted_at`); `UNIQUE(library_id, barcode)` tempatan |
| `sync_queue` | outbox; `operation_id` = kunci idempotensi pelayan |
| `sync_cursors` | `snapshot_xmin` per (perpustakaan, entiti) |

Fail `.g.dart` dijana (`dart run build_runner build`) dan di-commit.
SQLite dibundel dalam APK; ujian hos Linux guna `libsqlite3` sistem
(`hooks.user_defines` dalam `pubspec.yaml`).

## Konteks perpustakaan aktif – Fasa 3

`features/libraries/application/library_context.dart` (`LibraryContextController`):

1. Setiap sesi: senarai disahkan semula melalui `my_libraries()` (+ `system_admins`).
   Pilihan terakhir hanya *petunjuk* – dipulihkan hanya jika masih dibenarkan.
2. Tukar perpustakaan → `refresh()` dari pelayan dahulu (jika dalam talian),
   kemudian sahkan keahlian sebelum menukar konteks.
3. Perpustakaan yang aksesnya ditarik → data tempatannya dipadam.
4. Pengguna lain log masuk pada peranti yang sama → semua data tempatan dipadam
   (termasuk `device_id`, kerana `device_registry` milik seorang pengguna).
5. Semua provider per-perpustakaan `watch(activeLibraryProvider)`; skrin di-*key*
   dengan `library_id` → tiada data perpustakaan lama dipaparkan.
6. Luar talian: guna cache, ditanda "belum disahkan"; pelayan tetap
   menguatkuasakan RLS semasa sync.
7. Router: laluan per-perpustakaan (`/dashboard`, `/members`, `/library/edit`)
   dialih ke `/libraries` jika tiada perpustakaan aktif.

## Katalog (Fasa 4) – laluan tulis local-first

```
UI → CatalogActions (semak peranan, UX sahaja)
   → CatalogDao: SATU transaksi SQLite
        ├─ tulis baris local_* (sync_state = pending)
        └─ sync_queue (operation_id UUID, payload ikut lajur pelayan)
   → [Fasa 6] enjin sync → rpc/sync_push → RLS + kekangan pelayan
```

Penggabungan outbox (hanya operasi `pending`): insert+update → satu insert;
update+update → satu update (base_version asal); insert+delete → kedua-dua
dibuang; update+delete → satu delete. Bentuk payload diuji pada kedua-dua
belah (`test/unit/catalog_dao_test.dart` dan
`supabase/tests/database/50_catalog_payload_contract.sql`).

- **Barcode naskhah**: Code 128 (ASCII boleh cetak, ≤ 64). Jana sistem:
  `KODPUSTAKA-TAGPERANTI-NNNNNN` (tag 4 aksara daripada ID peranti + kaunter
  per perpustakaan). Peranti offline tidak boleh menjamin keunikan global;
  `UNIQUE(library_id, barcode)` pelayan menolak pertembungan dan pengguna boleh
  jana barcode baharu.
- **ISBN** disimpan dalam bentuk kanonik (ISBN-10 ditukar ke ISBN-13). Checksum
  salah hanya amaran (sesetengah penerbit mencetak ISBN tidak sah).
- **Metadata**: Google Books, kemudian Open Library. Hanya ISBN dihantar;
  hasil hanya mengisi medan kosong dan pengguna menyemak sebelum simpan.
- **Pendua**: dicadangkan (ISBN, kesamaan token tajuk/pengarang, penerbit,
  tahun) – tidak pernah digabung automatik; edisi lain boleh disimpan.
- **Pengimbas**: `mobile_scanner` (model ML Kit dibundel → berfungsi offline).
  Pengimbas fizikal USB/Bluetooth (keyboard wedge) disokong pada semua medan
  imbasan (kod + Enter).
- **Label**: PDF A4 3×8 (Code 128 + nama perpustakaan + tajuk ringkas + no.
  perolehan/panggilan) melalui `pdf` + `printing`.
- **Kulit buku**: URL https daripada metadata; muat naik gambar ke Storage
  belum dibina.

## Inventori (Fasa 5)

- **Stok tidak pernah disimpan sebagai kaunter.** Jumlah stok sentiasa dikira
  daripada `book_copies` (status + `deleted_at`), jadi tiada corak
  "baca jumlah → tambah → simpan" yang boleh rosak apabila ramai pengguna
  serentak. Lejar `stock_movements` hanya rekod peristiwa (append-only); jumlah
  kuantitinya sama dengan stok semasa (diuji di `60_inventory.sql`).
- **Pergerakan sementara (provisional)** dalam Drift (`local_stock_movements`,
  skema v2) direkod pada peranti mengikut peraturan yang SAMA dengan trigger
  pelayan (`copyMovement()` ↔ `tg_copy_stock_movement`, diuji dengan jadual
  kes yang sama di Dart dan SQL). Setiap baris dikaitkan dengan `operation_id`
  outbox; Fasa 6 akan menggantikannya dengan baris pelayan selepas disahkan.
- **Perubahan pukal** (tukar status, pindah lokasi, keadaan) dalam satu
  transaksi tempatan – semua atau tiada.
- **Semakan stok** per lokasi rak: imbasan disimpan selepas setiap imbasan
  (selamat jika aplikasi ditutup); di akhir, naskhah tidak dijumpai boleh
  ditanda Hilang dan naskhah di rak salah boleh dipindahkan – dengan rujukan
  "Semakan stok <tarikh>" pada setiap pergerakan.
- Pelayan: `created_at` lejar/audit kini `clock_timestamp()` supaya susunan
  sejarah dalam satu batch sync adalah tepat (migration 0900).

## Keputusan teknikal & andaian

| Perkara | Keputusan | Sebab |
|---|---|---|
| Flutter | ≥ 3.47 (diuji 3.50.0 / Dart 3.14.0) | `material_ui` – Material dipisahkan daripada framework sejak 3.47; `flutter/material.dart` kini *deprecated* |
| supabase_flutter | **2.18.3 (stabil)** | v3 masih `3.0.0-dev.*` (pra-keluaran) – tidak sesuai untuk produksi |
| State | Riverpod 3.5.0 | Sokongan override untuk ujian |
| Router | go_router 18.1.4 | `refreshListenable` untuk auth |
| Sesi | `flutter_secure_storage` 11.2.0 + PKCE | Token tidak disimpan dalam SharedPreferences biasa |
| minSdk Android | **24 (Android 7.0)** – lalai Flutter 3.50 | Flutter semasa tidak menyokong Android 6.0 (API 23). Lihat installation.md |
| ISBN | Tidak unik | Pengenal edisi; pendua dicadangkan, tidak digabung automatik |
| Barcode | `UNIQUE (library_id, barcode)` | Perlindungan terakhir terhadap pendua serentak/offline |
| Soft delete | `deleted_at` pada katalog | Tombstone untuk sync; hard delete hanya Library Admin (+ `sync_tombstones`) |
| Cursor sync | `xid8` transaksi (`pg_current_xact_id`) | Tidak bergantung pada jam peranti; tidak terlepas transaksi lambat. Lihat sync-design.md |
| Peranan | `viewer < staff < editor < library_admin`; Super Admin dalam `system_admins` | Super Admin tidak boleh diberi melalui API |
| Backup Android | `android:allowBackup="false"` | Elak salinan DB tempatan/token ke awan Google |
