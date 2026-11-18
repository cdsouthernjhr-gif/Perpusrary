-- =============================================================================
-- SmartLibrary Manager — 0900 Phase 5: inventory ledger ordering
--
-- now() is the TRANSACTION start time, so every movement / audit row written
-- in one transaction (e.g. a sync_push batch: status change then relocation
-- of the same copy) shared the same created_at and history order was
-- undefined. clock_timestamp() gives each row its own, increasing time.
-- Safe to re-run.
-- =============================================================================
alter table public.stock_movements alter column created_at set default clock_timestamp();
alter table public.activity_logs   alter column created_at set default clock_timestamp();
alter table public.sync_tombstones alter column deleted_at set default clock_timestamp();

-- History queries: newest first per copy / per library.
create index if not exists stock_movements_type_idx
  on public.stock_movements (library_id, movement_type, created_at desc);
