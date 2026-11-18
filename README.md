# SmartLibrary Manager

Aplikasi Android (Flutter) untuk pendaftaran, katalog dan inventori buku bagi
**banyak perpustakaan dalam satu sistem**, dengan Supabase (PostgreSQL + RLS)
sebagai pelayan dan SQLite/Drift sebagai pangkalan data tempatan (offline-first).

> Status: **Fasa 1–3 siap dan diuji** (seni bina, skema database, RLS, Auth,
> database tempatan Drift, Library Switcher, pengurusan pengguna, Dashboard).
> Fasa 4 dan seterusnya belum dibina.
> Lihat [docs/progress.md](docs/progress.md).

## Struktur

```
lib/                 Aplikasi Flutter (app/, core/, data/, features/, shared/)
supabase/
  migrations/        Migration SQL (idempoten, boleh diulang)
  tests/database/    Ujian RLS & keselamatan (SQL biasa, tanpa pgTAP)
  tests/helpers/     Pembantu ujian (schema "tests", dipasang sementara)
  tests/local_stub/  Stub platform Supabase untuk PostgreSQL biasa (ujian sahaja)
  config.toml        Konfigurasi Supabase CLI (tempatan)
  seed.sql           Data demo tempatan
scripts/             db_test.sh, db_concurrency_test.sh
test/                Ujian unit/widget/integration Flutter
docs/                Dokumentasi
```

## Mula pantas

1. Ikut [docs/installation.md](docs/installation.md) untuk menyediakan projek Supabase.
2. Salin `env/dev.example.json` → `env/dev.json` dan isi URL + **anon/publishable key** sahaja.
3. `flutter pub get`
4. `flutter run --dart-define-from-file=env/dev.json`

## Ujian

```bash
flutter analyze
flutter test
PGHOST=... PGPORT=... PGUSER=postgres ./scripts/db_test.sh   # migrations + RLS + concurrency
```

Butiran: [docs/testing.md](docs/testing.md).

## Dokumentasi

- [Seni bina](docs/architecture.md)
- [Skema database](docs/database-schema.md)
- [RLS & keselamatan](docs/rls-security.md)
- [Reka bentuk sync](docs/sync-design.md)
- [Pemasangan](docs/installation.md)
- [Ujian](docs/testing.md)
- [Kemajuan fasa](docs/progress.md)
