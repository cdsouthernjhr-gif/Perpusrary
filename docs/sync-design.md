# Reka Bentuk Sync (Offline-First)

> **Dibina dan diuji** – pelayan (Fasa 2, 6) dan peranti (Fasa 3–6).
> Enjin: `lib/data/sync/sync_engine.dart`. Ujian hujung-ke-hujung terhadap
> PostgreSQL sebenar: `test/integration/sync_engine_pg_test.dart`.

## Push – `rpc/sync_push(p_library_id, p_device_id, p_operations)`

Setiap operasi:

```json
{
  "operation_id": "uuid (dijana peranti, KUNCI IDEMPOTENSI)",
  "entity_type": "categories|locations|books|book_copies",
  "entity_id": "uuid (dijana peranti)",
  "operation_type": "insert|update|delete",
  "base_version": 3,
  "payload": { "title": "..." },
  "meta": { "reference_number": "PO-1", "remarks": "..." }
}
```

Pelayan (SECURITY INVOKER → RLS berkuat kuasa):

1. Sahkan sesi (`auth.uid()`) dan peranan ≥ staff dalam perpustakaan aktif.
2. Maks 200 operasi setiap batch.
3. Untuk setiap operasi:
   - `INSERT INTO sync_operations ... ON CONFLICT (operation_id) DO NOTHING`.
     Jika sudah wujud → pulangkan keputusan tersimpan (`"duplicate": true`),
     **tidak diproses semula**. Penghantaran serentak operation_id yang sama
     disirikan oleh kunci unik (diuji dengan 3 sesi serentak).
   - Laksana dalam sub-transaksi berasingan (satu ralat tidak menjejaskan
     operasi lain).
   - Hanya lajur senarai putih diterima (`library_id`, `version`,
     `created_by`, `deleted_at`, dll. diabaikan).
   - `update`/`delete` memerlukan `base_version == version` semasa;
     jika tidak → `conflict` + `server_row`.
4. Keputusan setiap operasi: `applied | conflict | rejected | failed` dengan
   `error_code`:

| error_code | Maksud | Tindakan peranti |
|---|---|---|
| `duplicate_barcode` | barcode telah digunakan (cth. peranti lain offline) | tandakan ralat, minta pengguna jana barcode baharu |
| `duplicate_accession_number`, `duplicate_category`, `duplicate_location` | pendua | papar & minta pembetulan |
| `version_mismatch` / `already_exists` | konflik | papar perbandingan; pengguna berkelayakan pilih |
| `forbidden` | peranan tidak mencukupi | jangan cuba semula |
| `invalid_reference`, `validation_failed`, `malformed_operation`, `not_found`, `deleted_on_server` | data tidak sah | jangan cuba semula; tunjuk dalam Sync Center |
| `server_error_*` (status `failed`) | ralat sementara | cuba semula (backoff) |

Operasi `rejected`/`conflict` **tidak** dicuba semula secara automatik.
Ralat rangkaian (tiada respons) → cuba semula dengan operation_id yang sama
(exponential backoff 2^n s, maks ~15 min, jitter) – selamat kerana idempoten.

## Pull – `rpc/sync_pull(p_library_id, p_entity_type, p_since, p_after_xid, p_after_id, p_limit)`

Cursor berasaskan **ID transaksi** (`xid8`), bukan jam peranti:

- Setiap tulisan menetapkan `sync_xid = pg_current_xact_id()` (trigger).
- Satu "pusingan" pull mengembalikan baris dengan `sync_xid >= p_since`,
  dipaginasi dengan keyset `(sync_xid, id) > (p_after_xid, p_after_id)`.
- Halaman **pertama** memulangkan `snapshot_xmin`. Apabila `has_more = false`,
  peranti menyimpan nilai itu sebagai `p_since` seterusnya.

Kenapa betul: mana-mana transaksi yang belum selesai semasa halaman pertama
mempunyai xid ≥ `snapshot_xmin`, jadi ia akan termasuk dalam pusingan
berikutnya. Baris mungkin dihantar semula (tidak mengapa: peranti upsert
berdasarkan `id` + `version` yang lebih tinggi). Cursor timestamp atau
sequence boleh terlepas transaksi panjang; ini tidak.

Jenis entiti: `categories, locations, books, book_copies, stock_movements,
sync_tombstones`. Padam lembut = baris dengan `deleted_at`; padam keras =
`sync_tombstones`.

## Peranti (Fasa 6 – dibina)

### Outbox (`sync_queue`)
- Setiap perubahan tempatan = baris rekod + operasi outbox dalam **satu
  transaksi SQLite**.
- Payload *update* hanya mengandungi **medan yang berubah** (diff). Oleh itu
  "Kekalkan perubahan saya" semasa konflik hanya menulis semula medan yang
  pengguna ini ubah, dan tidak membatalkan perubahan pengguna lain pada medan
  lain (pepijat ini ditemui oleh ujian integrasi dan dibetulkan).
- Penggabungan: insert+update → insert; update+update → update; insert+delete →
  dibuang; update+delete → delete. Operasi yang *parked* (konflik/ditolak) turut
  menyerap suntingan baharu bagi rekod yang sama.

### Keadaan operasi
`pending → in_flight → (dibuang apabila applied) | conflict | rejected | failed`

| Keadaan | Maksud | Tindakan |
|---|---|---|
| `in_flight` | sedang dihantar (atau aplikasi mati semasa hantar) | dihantar semula dengan operation_id yang SAMA |
| `failed` | rangkaian/ralat sementara | cuba semula selepas *backoff* (5 s × 2ⁿ, maks 15 min, ±20 % jitter) |
| `conflict` | versi pelayan berbeza | pengguna pilih di Sync Center |
| `rejected` | pelayan menolak (pendua, kebenaran, data tidak sah) | pengguna pilih di Sync Center |

Operasi diambil FIFO dan berhenti pada operasi pertama yang masih dalam
*backoff* (operasi kemudian mungkin bergantung padanya, cth. naskhah → buku).
Operasi bagi rekod yang sedang konflik/ditolak tidak dihantar sehingga
diselesaikan.

### Aliran satu sync (`SyncController.syncNow`)
1. Sahkan semula sesi + keahlian (`my_libraries()`); jika akses ditarik → henti.
2. Push batch ≤ 200 (`sync_push`); hasil diproses dalam satu transaksi.
   - `applied`: operasi dibuang; pergerakan stok sementara operasi itu dibuang
     (baris pelayan datang melalui pull); baris pelayan diambil – atau, jika ada
     suntingan lebih baharu, hanya versinya diambil dan operasi yang menunggu
     di-*rebase* ke versi itu (tiada konflik palsu).
   - `SyncTransportException` (termasuk respons hilang selepas pelayan commit):
     operasi → `failed` + backoff; dihantar semula kemudian dengan id yang
     sama → pelayan memulangkan keputusan tersimpan (`duplicate`).
   - `SyncAccessDenied` (42501/sesi tamat): operasi kembali `pending`, tidak
     hilang; konteks perpustakaan dimuat semula.
3. Pull setiap entiti (`categories, locations, books, book_copies,
   stock_movements, sync_tombstones`) dengan kursor `snapshot_xmin` halaman
   pertama. Baris yang mempunyai perubahan tempatan belum disahkan **tidak
   ditimpa** (push yang menentukan).
4. Kekangan barcode unik tempatan dibuang (skema v3) supaya pull tidak gagal
   apabila peranti lain sudah menggunakan barcode yang sama dengan naskhah
   tempatan yang belum diterima; pelayan menolak naskhah tempatan itu.

### Penyelesaian (Sync Center)
| Situasi | Pilihan |
|---|---|
| Konflik | Lihat perbezaan • Guna versi pelayan • Kekalkan perubahan saya (Editor+ untuk katalog, Staf+ untuk naskhah) |
| Ditolak: barcode pendua | Jana barcode baharu (dihantar semula) • Buang perubahan saya |
| Ditolak: lain-lain | Buang perubahan saya (baris pelayan dipulihkan – migration 1000 memulangkan `server_row` untuk penolakan) |
| Gagal | Cuba sekarang |

Operasi yang diselesaikan mendapat **operation_id baharu** (id lama sudah
direkod di pelayan dengan keputusan lama).

### Pencetus automatik (`SyncAutoRunner`)
Perpustakaan dipilih • sambungan kembali • 3 s selepas perubahan tempatan •
setiap 3 minit • aplikasi kembali ke hadapan. Satu sync pada satu masa bagi
setiap perpustakaan (*single-flight*).
