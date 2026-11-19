-- =============================================================================
-- SmartLibrary Manager — 1200 ISBN lookup: Library of Congress source
--
-- The app now also looks ISBNs up in the Library of Congress catalogue
-- (strong coverage of Malaysian / Southeast Asian publications), so
-- books.metadata_source accepts 'library_of_congress'.
-- Safe to re-run.
-- =============================================================================
alter table public.books drop constraint if exists books_metadata_source_check;
alter table public.books add constraint books_metadata_source_check
  check (metadata_source in ('manual', 'google_books', 'open_library', 'library_of_congress', 'import'));
