# Release (GitHub Actions)

Workflow `.github/workflows/release.yml` membina APK yang ditandatangani dengan
kunci anda sendiri, kemudian menerbitkannya sebagai **GitHub Release** (dengan
pautan muat turun). Anda tidak perlu Flutter di komputer.

Bahagian A dan B dibuat **sekali sahaja**. Bahagian C diulang untuk setiap
versi baharu.

## A. Cipta keystore (sekali sahaja, di komputer anda)

Keystore ialah "tandatangan" aplikasi. **Jika hilang, aplikasi tidak boleh
dikemas kini lagi.** Simpan fail `.jks` dan kata laluannya di dua tempat
selamat, contohnya pemacu USB dan pengurus kata laluan.

Anda perlu `keytool`. Ia didatangkan bersama Java atau Android Studio:
`C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe`.

PowerShell:

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkey -v `
  -keystore "$env:USERPROFILE\smartlibrary-release.jks" `
  -alias smartlibrary -keyalg RSA -keysize 2048 -validity 10000
```

- Masukkan kata laluan yang kuat; kata laluan ini digunakan untuk keystore dan kunci.
- Untuk nama dan organisasi, isi nama perpustakaan atau organisasi anda.

Tukar keystore kepada teks base64, yang akan disalin terus ke clipboard:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\smartlibrary-release.jks")) | Set-Clipboard
```

## B. Masukkan Secrets dalam GitHub (sekali sahaja)

Repo → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**. Tambah setiap secret berikut:

| Nama | Nilai |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | tampal teks base64 dari langkah A |
| `ANDROID_KEYSTORE_PASSWORD` | kata laluan keystore |
| `ANDROID_KEY_ALIAS` | `smartlibrary` |
| `ANDROID_KEY_PASSWORD` | kata laluan kunci (sama dengan di atas jika anda guna satu) |
| `SUPABASE_URL` | `https://ifzsuoxegomisfxkjcmk.supabase.co` |
| `SUPABASE_ANON_KEY` | kunci **publishable** (`sb_publishable_…`), BUKAN secret key |
| `GOOGLE_BOOKS_API_KEY` | (pilihan) |

GitHub menyulitkan secrets. Nilainya tidak dipaparkan dalam log, dan
tidak kelihatan kepada sesiapa selepas disimpan.

## C. Terbitkan versi (setiap release)

1. Pastikan `version:` dalam `pubspec.yaml` betul, contohnya `1.0.0+1`.
   Untuk setiap versi seterusnya, naikkan kedua-dua bahagian, contohnya
   `1.0.1+2`. Nombor selepas `+` mesti sentiasa bertambah.
2. GitHub → **Releases** → **Draft a new release**.
   - **Choose a tag**: taip `v1.0.0`, mesti sama dengan version tanpa `+…`,
     kemudian pilih *Create new tag*.
   - **Target**: pilih branch yang mengandungi kod terkini.
   - Tekan **Publish release**.
3. Tab **Actions** akan menunjukkan *Release APK* berjalan (kira-kira 10–15 minit).
   Workflow ini:
   - menyemak secrets dan kesepadanan versi;
   - menjalankan analyzer dan ujian;
   - membina APK, mengesahkan APK **bukan** ditandatangani dengan kunci debug,
     dan menjalankan audit keselamatan;
   - memadam fail kunci daripada mesin binaan;
   - melampirkan `SmartLibrary-<versi>-arm64.apk`,
     `SmartLibrary-<versi>-armv7.apk` dan `SHA256SUMS.txt` pada release.
4. Kongsi pautan halaman release dengan pengguna.

Jika workflow gagal, buka log dalam tab Actions. Mesej ralat dalam Bahasa
Melayu menerangkan puncanya, contohnya secret belum ditetapkan atau versi
tidak sepadan.

## Peralihan daripada APK ujian

APK ujian sebelum ini ditandatangani dengan kunci debug. Android tidak
membenarkan aplikasi dengan tandatangan berbeza dipasang di atasnya, jadi
peralihan perlu dibuat sekali sahaja:
1. Pada setiap telefon, buka Pusat Sync dan pastikan **tiada perubahan menunggu**.
2. Nyahpasang aplikasi ujian.
3. Pasang APK daripada GitHub Release, kemudian log masuk semula. Data akan
   dimuat turun semula dari pelayan.

Selepas itu, setiap versi baharu boleh dipasang terus di atas versi lama.
