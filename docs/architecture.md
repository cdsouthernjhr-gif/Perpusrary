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
