# Pemasangan & Konfigurasi

## 1. Semak persekitaran (Windows – mesin pembangunan anda)

Jangan pasang semula apa-apa yang sudah ada. Jalankan dan simpan output:

```powershell
flutter doctor -v
flutter --version
dart --version
java -version
```

Keperluan projek ini:

| Komponen | Minimum | Diuji |
|---|---|---|
| Flutter | **3.47** (keperluan `material_ui`) | 3.50.0 stable |
| Dart | 3.13 | 3.14.0 |
| JDK | 17 | – |
| Android SDK | compileSdk/targetSdk 36 | – |

Jika Flutter anda lebih lama daripada 3.47: `flutter upgrade` (tidak perlu
pasang semula).

### Android minimum

Flutter 3.50 menetapkan `minSdk = 24` (**Android 7.0**). **Android 6.0
(API 23) tidak disokong** oleh Flutter SDK semasa, jadi aplikasi ini tidak
menjanjikan sokongan Android 6.0. Jika ia benar-benar diperlukan, satu
penilaian berasingan diperlukan (versi Flutter lama + semua plugin yang serasi),
dengan risiko keselamatan dan sokongan.

## 2. Projek Supabase

1. Cipta satu projek di <https://supabase.com/dashboard>.
2. **Jalankan migration** (pilih satu):
   - Supabase CLI: `supabase link --project-ref <ref>` → `supabase db push`
   - Atau SQL Editor: jalankan setiap fail `supabase/migrations/*.sql` mengikut
     urutan nama. (Fail boleh dijalankan semula dengan selamat.)
3. **Jangan** jalankan `supabase/tests/local_stub/supabase_stub.sql` pada
   Supabase sebenar.
4. Settings → API → *Exposed schemas*: kekalkan `public` (dan `graphql_public`).
   **Jangan** tambah `private`.
5. Authentication → URL Configuration → *Redirect URLs*: tambah
   `my.smartlibrary.manager://auth-callback`.
6. Authentication → Providers → Email: aktifkan *Confirm email*. Untuk produksi,
   tetapkan SMTP sendiri.
7. Storage: bucket `library-assets` dan `library-backups` dicipta oleh migration
   (peribadi). Sahkan kedua-duanya **tidak** bertanda *Public*.

### Super Admin pertama

Selepas mendaftar akaun melalui aplikasi, di SQL Editor:

```sql
insert into public.system_admins (user_id)
select id from auth.users where email = 'emel.anda@contoh.my';
```

Super Admin kemudian boleh mencipta perpustakaan dan melantik Library Admin.

## 3. Konfigurasi aplikasi

```text
env/dev.example.json  →  salin ke env/dev.json (tidak di-commit)
```

Isi `SUPABASE_URL` dan **anon / publishable key** (Settings → API).
**Jangan sekali-kali** masukkan `service_role` / *secret key* – aplikasi akan
enggan bermula jika anda berbuat demikian.

```powershell
flutter pub get
flutter run --dart-define-from-file=env/dev.json
```

## 4. Bina APK

```powershell
flutter build apk --debug   --dart-define-from-file=env/dev.json
flutter build apk --release --dart-define-from-file=env/prod.json
```

Release memerlukan keystore sendiri (`android/key.properties`, tidak
di-commit). Konfigurasi signing akan ditambah dalam Fasa 8.

## 5. Pembangunan tempatan dengan Supabase CLI (pilihan)

```bash
supabase start          # Docker diperlukan
supabase db reset       # migrations + seed.sql
```

Emulator Android mencapai hos melalui `http://10.0.2.2:54321`.
