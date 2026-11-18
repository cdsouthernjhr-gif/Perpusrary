# Reka Bentuk Sync (Offline-First)

> Bahagian pelayan **sudah dibina dan diuji** (Fasa 2). Bahagian peranti
> (Drift, sync queue, worker) dirancang untuk Fasa 3 & 6.

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

## Peranti (Fasa 3/6 – dirancang)

Jadual Drift: cermin entiti + `local_status`, `server_version`;
`sync_queue(operation_id, library_id, entity_type, entity_id, op, base_version,
payload, attempts, next_attempt_at, last_error, state)`;
`sync_cursors(library_id, entity_type, since_xid)`.

Aliran apabila internet kembali:
1. Kumpul operasi `pending` (FIFO per entiti).
2. Sahkan/refresh sesi; panggil `my_libraries()` untuk sahkan keahlian.
3. `sync_push` dalam batch ≤ 200.
4. Kemas kini rekod tempatan daripada `server_row`; tandakan `applied`.
5. `conflict`/`rejected` → Sync Center; `failed`/rangkaian → backoff.
6. `sync_pull` setiap entiti hingga `has_more = false`; simpan cursor.

Rekod tempatan tidak dianggap disegerakkan sehingga pelayan mengembalikan
`applied`.
