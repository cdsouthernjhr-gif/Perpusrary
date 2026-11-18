-- =============================================================================
-- SmartLibrary Manager — 0200 Core tables
-- All tables use UUID primary keys. Every table that holds data owned by a
-- library has a NOT NULL library_id, and relationships between library-owned
-- rows use composite (library_id, id) foreign keys so a row can never point
-- at a row in a different library.
-- Safe to re-run (IF NOT EXISTS everywhere).
-- =============================================================================

-- ------------------------------------------------------------- libraries --
create table if not exists public.libraries (
  id                uuid primary key default gen_random_uuid(),
  name              text not null check (length(btrim(name)) between 2 and 200),
  code              text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$'),
  address           text check (length(address) <= 500),
  organization_name text check (length(organization_name) <= 200),
  logo_path         text check (length(logo_path) <= 500),
  contact_person    text check (length(contact_person) <= 200),
  phone             text check (length(phone) <= 50),
  email             text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  established_on    date,
  status            text not null default 'active' check (status in ('active', 'inactive')),
  version           bigint not null default 1,
  sync_xid          xid8,
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
-- Library code is unique across the whole system (case-insensitive).
create unique index if not exists libraries_code_key on public.libraries (upper(code));
create index if not exists libraries_name_trgm on public.libraries using gin (name extensions.gin_trgm_ops);

-- --------------------------------------------------------- system_admins --
-- Super Admins. Managed ONLY by the database owner (SQL editor / migration).
-- No INSERT/UPDATE/DELETE policy exists, so the API can never grant this.
create table if not exists public.system_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  note       text,
  created_at timestamptz not null default now()
);

-- --------------------------------------------------------- user_profiles --
create table if not exists public.user_profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text check (length(full_name) <= 200),
  phone       text check (length(phone) <= 50),
  avatar_path text check (length(avatar_path) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ------------------------------------------------------- library_members --
create table if not exists public.library_members (
  id                uuid primary key default gen_random_uuid(),
  library_id        uuid not null references public.libraries(id) on delete cascade,
  user_id           uuid not null references auth.users(id) on delete cascade,
  role              text not null check (role in ('library_admin', 'editor', 'staff', 'viewer')),
  membership_status text not null default 'active'
                    check (membership_status in ('active', 'suspended', 'removed')),
  invited_by        uuid references auth.users(id) on delete set null,
  joined_at         timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint library_members_library_user_key unique (library_id, user_id)
);
create index if not exists library_members_user_idx on public.library_members (user_id) include (library_id, role, membership_status);

-- --------------------------------------------------- library_invitations --
create table if not exists public.library_invitations (
  id          uuid primary key default gen_random_uuid(),
  library_id  uuid not null references public.libraries(id) on delete cascade,
  email       text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role        text not null check (role in ('library_admin', 'editor', 'staff', 'viewer')),
  status      text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  invited_by  uuid references auth.users(id) on delete set null,
  expires_at  timestamptz not null default (now() + interval '14 days'),
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- Only one pending invitation per (library, email).
create unique index if not exists library_invitations_pending_key
  on public.library_invitations (library_id, lower(email)) where status = 'pending';
create index if not exists library_invitations_email_idx on public.library_invitations (lower(email)) where status = 'pending';

-- ------------------------------------------------------- device_registry --
create table if not exists public.device_registry (
  id           uuid primary key,              -- generated on the device
  user_id      uuid not null references auth.users(id) on delete cascade,
  device_name  text check (length(device_name) <= 200),
  platform     text not null default 'android' check (platform in ('android')),
  app_version  text check (length(app_version) <= 50),
  last_seen_at timestamptz,
  status       text not null default 'active' check (status in ('active', 'revoked')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists device_registry_user_idx on public.device_registry (user_id);
