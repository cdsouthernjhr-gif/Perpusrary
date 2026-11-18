# Laporan Kemajuan Fasa

## Fasa 1 – Audit & struktur ✅

### Audit persekitaran (2026-11-18)

Pembangunan dijalankan dalam **container Linux awan**, bukan mesin Windows
pengguna. Penemuan:

| Item | Keputusan |
|---|---|
| Repository | Kosong (tiada commit, tiada fail) – tiada kod sedia ada untuk dipelihara |
| Flutter | Tiada dalam container → Flutter **3.50.0** stable dimuat turun ke direktori sementara (bukan dipasang pada mesin pengguna) |
| Dart | 3.14.0 |
| Java | OpenJDK 21.0.13 |
| Android SDK | **Tiada**; `dl.google.com` disekat oleh polisi rangkaian → **APK tidak dapat dibina di sini** |
| PostgreSQL | 16.15 tersedia → digunakan untuk ujian migration/RLS |
| Supabase CLI / pgTAP / Docker Hub | Tidak tersedia (GitHub release disekat) → ujian ditulis dalam SQL biasa + stub platform |
| Mesin Windows pengguna | **Belum diaudit** – sila jalankan arahan dalam installation.md §1 |

### Dibina
- Projek Flutter (Android sahaja), struktur folder mengikut spesifikasi.
- Seni bina & keputusan teknikal: `docs/architecture.md`.
- Dependency dipin tepat + `pubspec.lock` di-commit.

## Fasa 2 – Auth, migration, multi-library, RLS, ujian keselamatan ✅

### Migration
`20261118000100_foundation` · `…0200_core_tables` · `…0300_catalog_tables` ·
`…0400_functions_and_triggers` · `…0500_rls_policies` · `…0600_rpc_functions` ·
`…0700_storage`

### Ujian dijalankan (PostgreSQL 16.15 + stub Supabase)

| Suite | Keputusan |
|---|---|
| Migration dijalankan 2× (idempoten) | ✅ lulus |
| `00_schema_audit.sql` | ✅ 9/9 |
| `10_rls_isolation.sql` (termasuk 7 ujian wajib) | ✅ lulus |
| `20_sync.sql` | ✅ lulus |
| `30_invitations_storage.sql` | ✅ lulus |
| Concurrency (C1 barcode serentak, C2 operation_id serentak ×3, C3 2×25 naskhah) | ✅ 3/3 |
| **Jumlah assertion** | **153 lulus, 0 gagal** |
| `flutter analyze` | ✅ tiada isu |
| `flutter test` | ✅ 19/19 |

### Masalah / had yang masih ada
1. Migration belum dijalankan pada projek Supabase **sebenar** (hanya
   PostgreSQL 16 + stub). Perlu disahkan sekali pada Supabase (CLI atau
   SQL Editor) – terutamanya polisi `storage.objects` dan trigger pada
   `auth.users`.
2. Aplikasi belum dijalankan pada peranti/emulator Android; APK belum dibina.
3. `supabase/config.toml` belum disahkan dengan Supabase CLI.
4. CI GitHub Actions (`.github/workflows/ci.yml`) ditambah tetapi belum
   pernah dijalankan.
5. Skrin "Pilih Perpustakaan" ialah pemegang tempat (memanggil
   `my_libraries()` terus) – akan diganti dalam Fasa 3.
6. Jemputan: e-mel jemputan belum dihantar automatik (memerlukan Edge
   Function dengan kunci pelayan – tidak boleh dalam APK). Buat masa ini
   penerima melihat jemputan *pending* selepas log masuk dengan e-mel yang sama.

### Langkah seterusnya – Fasa 3
- Drift/SQLite: skema tempatan, DAO, `sync_queue`, `sync_cursors`.
- Library Switcher sebenar (logo, kiraan, status sync; cache tempatan +
  pengesahan semula `my_libraries()` setiap sesi; pembersihan konteks
  apabila bertukar perpustakaan).
- Pengurusan pengguna (senarai ahli, jemput, tukar peranan, nyahaktif).
- Dashboard (`library_dashboard()`).
