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

### Langkah seterusnya (asal) – Fasa 3
- Drift/SQLite: skema tempatan, DAO, `sync_queue`, `sync_cursors`.
- Library Switcher sebenar (logo, kiraan, status sync; cache tempatan +
  pengesahan semula `my_libraries()` setiap sesi; pembersihan konteks
  apabila bertukar perpustakaan).
- Pengurusan pengguna (senarai ahli, jemput, tukar peranan, nyahaktif).
- Dashboard (`library_dashboard()`).

## Fasa 3 – Database tempatan, Library Switcher, pengguna, Dashboard ✅

### Dibina
- **Drift/SQLite** skema v1 (perpustakaan, katalog, `sync_queue`, `sync_cursors`, key-value) + DAO.
- **LibraryContextController**: pengesahan semula keahlian setiap sesi & setiap
  pertukaran, pemadaman data perpustakaan yang aksesnya ditarik, pemadaman data
  apabila pengguna lain log masuk pada peranti sama, pendaftaran peranti.
- **Library Switcher**: nama, logo (inisial), kod, peranan, jumlah judul/naskhah,
  status aktif, penunjuk sync, carian, jemputan, mod luar talian.
- **Tambah/Edit perpustakaan** (Super Admin cipta + jemput Library Admin pertama;
  Library Admin edit maklumat; hanya Super Admin aktif/nyahaktif & tukar kod).
- **Pengurusan pengguna**: senarai ahli, jemput, batal jemputan, tukar peranan,
  nyahaktif/aktif semula; skrin "Jemputan Saya" + terima.
- **Dashboard**: nama perpustakaan aktif jelas, butang tukar, penunjuk sync,
  statistik (judul, naskhah, hari ini, kategori, lokasi; admin: pengguna aktif,
  sedang sync, gagal sync, peranti), status naskhah, ringkasan kategori,
  aktiviti terkini; fallback statistik tempatan apabila luar talian.
- **Tetapan**: profil (nama, telefon), status pengesahan, log keluar dengan
  amaran perubahan belum sync.
- Menu modul (drawer) – modul fasa akan datang dipaparkan sebagai "Akan datang".

### Migration
`20261118000800_phase3_members_libraries.sql`

### Pepijat ditemui & dibetulkan oleh ujian
1. Super Admin `INSERT … RETURNING` pada `libraries` ditolak RLS (subkueri polisi
   SELECT tidak nampak baris baharu) → polisi SELECT kini membenarkan Super Admin.
2. Trigger audit gagal (FK) apabila seluruh perpustakaan dipadam → anak tidak
   dilog; pemadaman perpustakaan dilog sebagai peristiwa sistem.
3. `refresh()` semasa `initialize()` memadam pilihan perpustakaan terakhir
   sebelum dipulihkan → kini hanya dipadam jika perpustakaan aktif ditarik.

### Ujian dijalankan

| Suite | Keputusan |
|---|---|
| Migration ×2 + DB (00–40) + concurrency | ✅ **171 assertion lulus, 0 gagal** |
| `flutter analyze` | ✅ tiada isu |
| `flutter test` | ✅ **40/40** (unit 33, widget 7) |

### Masalah / had yang masih ada
1. Semua perkara dari Fasa 2 masih terpakai: belum diuji pada Supabase sebenar
   dan peranti Android sebenar; APK belum dibina (tiada Android SDK di sini).
2. Muat naik logo perpustakaan belum dibina (inisial dipaparkan) – akan
   digabungkan dengan muat naik kulit buku (Fasa 4).
3. "Sedang sync" pada penunjuk bergantung pada enjin sync (Fasa 6);
   kini penunjuk berdasarkan sambungan + `sync_queue`.
4. Penghantaran e-mel jemputan automatik masih belum (perlu Edge Function).
5. Nama peranti menggunakan ID ringkas (tiada plugin maklumat peranti).

### Langkah seterusnya – Fasa 4
Katalog buku (tambah/edit/cari/soft delete, pengesanan pendua), imbasan ISBN
(kamera + manual, Google Books / Open Library), naskhah & barcode (Code 128,
jana/imbas/cetak label), kategori, lokasi rak – semuanya ditulis ke Drift +
`sync_queue` terlebih dahulu.

## Fasa 4 – Katalog, ISBN, naskhah, barcode, kategori, lokasi ✅

### Dibina
- **Katalog buku**: senarai (carian tajuk/pengarang/ISBN, penapis kategori,
  jumlah naskhah, status sync), daftar, edit, padam lembut (ditolak jika masih
  ada naskhah aktif), butiran buku, kulit buku (URL metadata).
- **ISBN**: imbas kamera (EAN-13, hanya ISBN sah diterima), taip, pengimbas
  fizikal; normalisasi + checksum; carian metadata Google Books → Open Library;
  pendaftaran tetap boleh tanpa metadata.
- **Pengesanan pendua**: ISBN, tajuk, pengarang, penerbit, tahun – dialog
  cadangan (buka rekod sedia ada / simpan sebagai rekod baharu / batal).
- **Naskhah**: tambah semasa daftar (1–50, barcode dijana) atau kemudian;
  edit status/keadaan/lokasi/perolehan/kos; padam lembut (barcode kekal
  terpelihara); skrin Pengurusan Naskhah (carian + penapis status).
- **Barcode**: sedia ada atau jana sistem, Code 128, imbas kamera, pengimbas
  keyboard-wedge, cetak label PDF, cari naskhah melalui barcode; pendua
  ditolak dengan dialog (lihat rekod sedia ada / jana baharu).
- **Kategori** dan **Lokasi Rak** (bangunan/bilik/seksyen/rak/para) – tambah,
  edit, padam (lokasi yang digunakan tidak boleh dipadam).
- **Sejarah perubahan**: operasi tempatan belum disahkan + log aktiviti pelayan.
- Semua penulisan: SQLite + `sync_queue` dalam satu transaksi.

### Migration
Tiada migration baharu (skema pelayan Fasa 2/3 sudah mencukupi). Ujian
kontrak `50_catalog_payload_contract.sql` ditambah.

### Pepijat ditemui & dibetulkan oleh ujian
1. Limpahan teks status sync pada Butiran Buku (Row tanpa Flexible).
2. Limpahan jubin statistik **Dashboard (Fasa 3)** pada telefon 360dp.
3. Dropdown lokasi/kategori dengan label panjang melimpah 164px.

### Ujian dijalankan

| Suite | Keputusan |
|---|---|
| DB: migration ×2, 00–50, concurrency | ✅ **180 assertion lulus, 0 gagal** |
| `flutter analyze` | ✅ tiada isu |
| `flutter test` | ✅ **73/73** (unit 59, widget 14) |

### Masalah / had yang masih ada
1. **Data katalog belum dihantar ke pelayan** – baris gilir sync sudah lengkap
   tetapi enjin push/pull ialah Fasa 6. Buat masa ini setiap peranti hanya
   melihat data yang didaftarkan padanya.
2. Pengimbas kamera, cetakan sebenar dan carian metadata sebenar belum diuji pada
   peranti Android (ujian menggunakan input simulasi dan HTTP palsu).
3. Muat naik gambar kulit buku/logo ke Supabase Storage belum dibina.
4. Op `in_flight` tidak digabungkan; edit semasa penghantaran akan
   menghasilkan update dengan base_version lama → enjin Fasa 6 perlu
   *rebase* selepas keputusan pelayan diterima.

### Langkah seterusnya – Fasa 5
Inventori (tambah stok, pelarasan, tanda rosak/hilang/tidak aktif, pindah
lokasi secara pukal, sejarah pergerakan stok, laporan inventori), activity log
dalam aplikasi, dan ujian concurrency berbilang pengguna tambahan.

## Fasa 5 – Inventori, log aktiviti, concurrency berbilang pengguna ✅

### Dibina
- **Skrin Inventori**: laporan (judul, naskhah, dalam stok, nilai perolehan,
  mengikut status / keadaan / lokasi rak / kategori, amaran perubahan belum
  sync) dan pintasan tindakan.
- **Tukar status pukal** (rosak / hilang / tidak aktif / tersedia / dalam proses)
  dan **pindah lokasi pukal** melalui sesi imbasan (kamera atau pengimbas
  fizikal), dengan no. rujukan & catatan; satu transaksi.
- **Semakan stok** per rak: dijumpai / belum dijumpai / rak salah; sesi
  disimpan selepas setiap imbasan; tamatkan dengan tanda Hilang dan/atau
  pindah ke rak ini.
- **Sejarah pergerakan stok** (keseluruhan dan per naskhah dari borang naskhah),
  dengan tanda "belum disahkan" untuk perubahan tempatan.
- **Log Aktiviti** (pelayan, berhalaman, penapis jenis rekod, nama pengguna);
  mesej jelas apabila luar talian.
- "Tambah stok / tambah naskhah" menggunakan aliran Fasa 4 (daftar buku /
  tambah naskhah); setiap penambahan direkod sebagai pergerakan *acquisition*.
- Drift skema **v2** (`local_stock_movements`) dengan migrasi dari v1.

### Migration
`20261118000900_phase5_inventory.sql`

### Pepijat ditemui & dibetulkan oleh ujian
1. **Pelayan**: semua pergerakan stok/audit dalam satu transaksi (cth. satu
   batch sync) mendapat `created_at` yang sama → susunan sejarah tidak tentu.
   Kini `clock_timestamp()`.
2. Semakan stok tersekat menunggu getaran (haptic) selesai → kini tidak
   menyekat.

### Ujian dijalankan

| Suite | Keputusan |
|---|---|
| DB: migration ×2, 00–60, concurrency C1–C4 | ✅ **200 assertion lulus, 0 gagal** |
| `flutter analyze` | ✅ tiada isu |
| `flutter test` | ✅ **97/97** (unit 78, widget 19) |

### Masalah / had yang masih ada
1. **Enjin sync (Fasa 6) belum dibina**: perubahan inventori, katalog dan
   pergerakan sementara kekal dalam peranti; log aktiviti hanya menunjukkan
   perubahan yang sudah sampai ke pelayan.
2. Laporan inventori dikira daripada data dalam peranti; selepas Fasa 6 ia
   akan merangkumi data semua peranti. Eksport laporan ialah Fasa 7.
3. Belum diuji pada peranti Android sebenar.

### Langkah seterusnya – Fasa 6
Enjin sync: push batch dengan retry + exponential backoff, pull berkursor
(`sync_pull`), penggantian pergerakan sementara dengan baris pelayan,
pengendalian konflik (pilihan pengguna berkelayakan), *rebase* operasi yang
disunting semasa penghantaran, Sync Center, penunjuk "sedang sync", dan ujian
putus internet ketika sync.
