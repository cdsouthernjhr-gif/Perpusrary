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
| Concurrency sebenar (2–3 sambungan serentak) | `scripts/db_concurrency_test.sh` – barcode sama serentak, operation_id sama serentak, 2×25 naskhah serentak |

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

`test/integration/` – disediakan untuk Fasa 8 (perlu peranti/emulator Android).

## Yang BELUM diuji

- Aplikasi pada peranti Android sebenar / emulator (tiada Android SDK dalam
  persekitaran CI ini).
- Migration pada projek Supabase *hosted* sebenar (diuji pada PostgreSQL 16 +
  stub; perlu disahkan sekali pada Supabase – lihat progress.md).
- Aliran e-mel Supabase Auth sebenar (pengesahan, reset kata laluan).
