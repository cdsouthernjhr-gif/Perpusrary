-- =============================================================================
-- SmartLibrary Manager — 0300 Catalog, inventory, audit & sync tables
-- Safe to re-run.
-- =============================================================================

-- ------------------------------------------------------------ categories --
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid not null references public.libraries(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 120),
  code        text check (length(code) <= 40),        -- e.g. DDC class "813"
  description text check (length(description) <= 1000),
  version     bigint not null default 1,
  sync_xid    xid8,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  constraint categories_library_id_id_key unique (library_id, id)
);
create unique index if not exists categories_name_key
  on public.categories (library_id, lower(btrim(name))) where deleted_at is null;
create index if not exists categories_sync_idx on public.categories (library_id, sync_xid);

-- ------------------------------------------------------------- locations --
create table if not exists public.locations (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid not null references public.libraries(id) on delete cascade,
  building    text check (length(building) <= 100),
  room        text check (length(room) <= 100),
  section     text check (length(section) <= 100),
  rack_code   text not null check (length(btrim(rack_code)) between 1 and 40),
  shelf_code  text check (length(shelf_code) <= 40),
  description text check (length(description) <= 1000),
  version     bigint not null default 1,
  sync_xid    xid8,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  constraint locations_library_id_id_key unique (library_id, id)
);
create unique index if not exists locations_slot_key on public.locations (
  library_id,
  lower(coalesce(building, '')), lower(coalesce(room, '')), lower(coalesce(section, '')),
  lower(rack_code), lower(coalesce(shelf_code, ''))
) where deleted_at is null;
create index if not exists locations_sync_idx on public.locations (library_id, sync_xid);

-- ----------------------------------------------------------------- books --
-- One row per title/edition. ISBN identifies the edition, NOT a physical copy.
create table if not exists public.books (
  id               uuid primary key default gen_random_uuid(),
  library_id       uuid not null references public.libraries(id) on delete cascade,
  title            text not null check (length(btrim(title)) between 1 and 500),
  subtitle         text check (length(subtitle) <= 500),
  isbn             text check (isbn ~ '^(\d{9}[\dX]|\d{13})$'),  -- normalised, no hyphens
  author           text check (length(author) <= 500),
  publisher        text check (length(publisher) <= 300),
  publication_year int check (publication_year between 1000 and 2200),
  edition          text check (length(edition) <= 100),
  language         text check (length(language) <= 50),
  description      text check (length(description) <= 5000),
  category_id      uuid,
  call_number      text check (length(call_number) <= 60),
  cover_image_path text check (length(cover_image_path) <= 500),
  metadata_source  text check (metadata_source in ('manual', 'google_books', 'open_library', 'import')),
  version          bigint not null default 1,
  sync_xid         xid8,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  constraint books_library_id_id_key unique (library_id, id),
  constraint books_category_fk foreign key (library_id, category_id)
    references public.categories (library_id, id) on delete set null (category_id)
);
-- ISBN deliberately NOT unique: different records may legitimately share an
-- ISBN (re-catalogued editions, bad publisher ISBNs). Duplicates are
-- *suggested* to the user, never merged automatically.
create index if not exists books_isbn_idx on public.books (library_id, isbn) where deleted_at is null;
create index if not exists books_title_trgm on public.books using gin (title extensions.gin_trgm_ops);
create index if not exists books_author_trgm on public.books using gin (author extensions.gin_trgm_ops);
create index if not exists books_category_idx on public.books (library_id, category_id);
create index if not exists books_sync_idx on public.books (library_id, sync_xid);

-- ----------------------------------------------------------- book_copies --
-- One row per physical copy. Barcode is unique within a library.
create table if not exists public.book_copies (
  id                 uuid primary key default gen_random_uuid(),
  library_id         uuid not null references public.libraries(id) on delete cascade,
  book_id            uuid not null,
  barcode            text not null check (barcode ~ '^[!-~]{1,64}$'),  -- printable ASCII, Code 128 compatible
  accession_number   text check (length(accession_number) between 1 and 64),
  condition          text not null default 'good' check (condition in ('new', 'good', 'fair', 'poor', 'damaged')),
  location_id        uuid,
  acquisition_date   date,
  acquisition_source text check (acquisition_source in ('purchase', 'donation', 'grant', 'exchange', 'other')),
  acquisition_cost   numeric(12, 2) check (acquisition_cost >= 0),
  status             text not null default 'available'
                     check (status in ('available', 'in_processing', 'damaged', 'lost', 'inactive')),
  remarks            text check (length(remarks) <= 1000),
  version            bigint not null default 1,
  sync_xid           xid8,
  created_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  constraint book_copies_library_id_id_key unique (library_id, id),
  -- Final safety net against duplicate barcodes (incl. concurrent writers and
  -- offline devices). Soft-deleted copies keep their barcode reserved.
  constraint book_copies_library_barcode_key unique (library_id, barcode),
  constraint book_copies_book_fk foreign key (library_id, book_id)
    references public.books (library_id, id),
  constraint book_copies_location_fk foreign key (library_id, location_id)
    references public.locations (library_id, id) on delete set null (location_id)
);
create unique index if not exists book_copies_accession_key
  on public.book_copies (library_id, accession_number) where accession_number is not null;
create index if not exists book_copies_book_idx on public.book_copies (library_id, book_id);
create index if not exists book_copies_location_idx on public.book_copies (library_id, location_id);
create index if not exists book_copies_status_idx on public.book_copies (library_id, status) where deleted_at is null;
create index if not exists book_copies_sync_idx on public.book_copies (library_id, sync_xid);

-- ------------------------------------------------------- stock_movements --
-- Append-only inventory ledger. Rows are written by the server-side trigger
-- on book_copies (see 0400), so they always match the actual state change.
create table if not exists public.stock_movements (
  id               uuid primary key default gen_random_uuid(),
  library_id       uuid not null references public.libraries(id) on delete cascade,
  copy_id          uuid not null,
  movement_type    text not null check (movement_type in (
                     'acquisition', 'status_change', 'relocation', 'adjustment', 'removal', 'restoration')),
  quantity         int not null check (quantity between -1 and 1),
  from_status      text,
  to_status        text,
  from_location_id uuid,
  to_location_id   uuid,
  reference_number text check (length(reference_number) <= 100),
  remarks          text check (length(remarks) <= 1000),
  sync_xid         xid8 not null default pg_catalog.pg_current_xact_id(),
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint stock_movements_copy_fk foreign key (library_id, copy_id)
    references public.book_copies (library_id, id)
);
create index if not exists stock_movements_copy_idx on public.stock_movements (library_id, copy_id, created_at desc);
create index if not exists stock_movements_created_idx on public.stock_movements (library_id, created_at desc);
create index if not exists stock_movements_sync_idx on public.stock_movements (library_id, sync_xid);

-- --------------------------------------------------------- activity_logs --
-- library_id is NULL only for system-level events (visible to Super Admins).
create table if not exists public.activity_logs (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid references public.libraries(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,
  action      text not null check (length(action) between 1 and 60),
  entity_type text not null check (length(entity_type) between 1 and 60),
  entity_id   uuid,
  details     jsonb not null default '{}'::jsonb,
  device_id   uuid,
  created_at  timestamptz not null default now()
);
create index if not exists activity_logs_library_idx on public.activity_logs (library_id, created_at desc);
create index if not exists activity_logs_entity_idx on public.activity_logs (library_id, entity_type, entity_id);

-- ------------------------------------------------------- sync_operations --
create table if not exists public.sync_operations (
  id             uuid primary key default gen_random_uuid(),
  library_id     uuid not null references public.libraries(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  device_id      uuid,
  operation_id   uuid not null,
  entity_type    text not null check (entity_type in ('categories', 'locations', 'books', 'book_copies')),
  entity_id      uuid not null,
  operation_type text not null check (operation_type in ('insert', 'update', 'delete')),
  base_version   bigint,
  payload        jsonb not null default '{}'::jsonb,
  sync_status    text not null default 'processing'
                 check (sync_status in ('processing', 'applied', 'conflict', 'rejected', 'failed')),
  error_code     text,
  error_message  text,
  result         jsonb,
  created_at     timestamptz not null default now(),
  processed_at   timestamptz,
  -- Idempotency key: the same operation is never applied twice.
  constraint sync_operations_operation_id_key unique (operation_id)
);
create index if not exists sync_operations_library_idx on public.sync_operations (library_id, created_at desc);
create index if not exists sync_operations_device_idx on public.sync_operations (library_id, device_id, processed_at desc);
create index if not exists sync_operations_failed_idx on public.sync_operations (library_id, sync_status)
  where sync_status in ('conflict', 'rejected', 'failed');

-- ------------------------------------------------------- sync_tombstones --
-- Records hard deletes so that offline devices learn about them on pull.
create table if not exists public.sync_tombstones (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid not null references public.libraries(id) on delete cascade,
  entity_type text not null,
  entity_id   uuid not null,
  deleted_by  uuid references auth.users(id) on delete set null,
  sync_xid    xid8 not null default pg_catalog.pg_current_xact_id(),
  deleted_at  timestamptz not null default now()
);
create index if not exists sync_tombstones_sync_idx on public.sync_tombstones (library_id, sync_xid);

-- ----------------------------------------------------------- import_jobs --
create table if not exists public.import_jobs (
  id              uuid primary key default gen_random_uuid(),
  library_id      uuid not null references public.libraries(id) on delete cascade,
  uploaded_by     uuid references auth.users(id) on delete set null,
  file_name       text not null check (length(file_name) <= 255),
  duplicate_mode  text not null default 'skip' check (duplicate_mode in ('skip', 'update', 'insert_new')),
  status          text not null default 'pending'
                  check (status in ('pending', 'validating', 'importing', 'completed', 'failed', 'cancelled')),
  total_rows      int not null default 0 check (total_rows >= 0),
  successful_rows int not null default 0 check (successful_rows >= 0),
  failed_rows     int not null default 0 check (failed_rows >= 0),
  error_summary   jsonb not null default '[]'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  completed_at    timestamptz
);
create index if not exists import_jobs_library_idx on public.import_jobs (library_id, created_at desc);

-- -------------------------------------------------------- backup_records --
create table if not exists public.backup_records (
  id            uuid primary key default gen_random_uuid(),
  library_id    uuid not null references public.libraries(id) on delete cascade,
  created_by    uuid references auth.users(id) on delete set null,
  file_path     text check (length(file_path) <= 500),
  backup_type   text not null default 'manual' check (backup_type in ('manual', 'automatic', 'pre_restore')),
  status        text not null default 'pending' check (status in ('pending', 'completed', 'failed')),
  file_size     bigint check (file_size >= 0),
  checksum      text check (length(checksum) <= 128),
  record_counts jsonb not null default '{}'::jsonb,
  notes         text check (length(notes) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- Backup objects must live under the library's own Storage folder.
  constraint backup_records_path_check check (file_path is null or file_path like library_id::text || '/%')
);
create index if not exists backup_records_library_idx on public.backup_records (library_id, created_at desc);
