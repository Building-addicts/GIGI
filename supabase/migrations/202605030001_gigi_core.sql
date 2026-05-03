-- GIGI Supabase Core v1
-- Identity + devices + channels + conversation ledger + permissioned actions
-- + privacy-first memory + KILLSIRI waitlist/governance.
-- Run with Supabase CLI migrations or paste into Dashboard SQL Editor.
--
-- IMPORTANT: run this ENTIRE file in one go (not snippets). Procedure: supabase/DEPLOY-IT.md

begin;

create schema if not exists extensions;

-- Extensions live in Supabase's extensions schema to avoid public namespace pollution.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists private;

-- Keep helper/RPC functions deterministic and safe under SECURITY DEFINER.
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Shared updated_at trigger
-- ---------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- GENERATED STORED cols must use IMMUTABLE expressions; to_tsvector() is STABLE only.
create or replace function private.memory_items_refresh_search_vector()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.search_vector := to_tsvector(
    'simple',
    coalesce(new.text, '') || ' ' || coalesce(array_to_string(new.tags, ' '), '')
  );
  return new;
end;
$$;

-- Same pattern: keep normalized email deterministic without GENERATED (portable across PG/Supabase).
create or replace function private.waitlist_signups_refresh_email_normalized()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.email_normalized := lower(trim(new.email));
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------
create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text,
  primary_email text,
  home_timezone text,
  locale text not null default 'en',
  status text not null default 'active' check (status in ('active', 'paused', 'deleted')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists app_users_primary_email_lower_idx
  on public.app_users (lower(primary_email))
  where primary_email is not null;

drop trigger if exists app_users_set_updated_at on public.app_users;
create trigger app_users_set_updated_at
  before update on public.app_users
  for each row execute function private.set_updated_at();

create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  device_hash text not null unique,
  display_name text,
  platform text not null default 'ios' check (platform in ('ios', 'web', 'macos', 'android', 'server', 'unknown')),
  trusted boolean not null default false,
  push_token_hash text,
  last_seen_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists user_devices_owner_idx on public.user_devices(owner_user_id);

drop trigger if exists user_devices_set_updated_at on public.user_devices;
create trigger user_devices_set_updated_at
  before update on public.user_devices
  for each row execute function private.set_updated_at();

create table if not exists public.channel_identities (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  channel text not null check (channel in ('ios', 'whatsapp', 'telegram', 'email', 'web', 'api')),
  external_identity_hash text not null,
  display_label text,
  is_primary boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (channel, external_identity_hash)
);

create index if not exists channel_identities_owner_idx on public.channel_identities(owner_user_id);

drop trigger if exists channel_identities_set_updated_at on public.channel_identities;
create trigger channel_identities_set_updated_at
  before update on public.channel_identities
  for each row execute function private.set_updated_at();

create table if not exists public.external_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  provider text not null,
  account_label text,
  account_hash text,
  status text not null default 'connected' check (status in ('connected', 'expired', 'revoked', 'error')),
  scopes text[] not null default '{}'::text[],
  token_ref text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_user_id, provider, account_hash)
);

create index if not exists external_accounts_owner_idx on public.external_accounts(owner_user_id);

drop trigger if exists external_accounts_set_updated_at on public.external_accounts;
create trigger external_accounts_set_updated_at
  before update on public.external_accounts
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Conversations: append-only enough for audit/replay, compact enough for MVP.
-- ---------------------------------------------------------------------------
create table if not exists public.conversation_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  device_id uuid references public.user_devices(id) on delete set null,
  channel text not null default 'ios' check (channel in ('ios', 'whatsapp', 'telegram', 'email', 'web', 'api')),
  title text,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  summary text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists conversation_sessions_owner_started_idx
  on public.conversation_sessions(owner_user_id, started_at desc);

drop trigger if exists conversation_sessions_set_updated_at on public.conversation_sessions;
create trigger conversation_sessions_set_updated_at
  before update on public.conversation_sessions
  for each row execute function private.set_updated_at();

create table if not exists public.conversation_messages (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.conversation_sessions(id) on delete cascade,
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  role text not null check (role in ('user', 'assistant', 'system', 'tool')),
  content text not null,
  tool_name text,
  tool_call_id text,
  model text,
  token_count integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists conversation_messages_session_created_idx
  on public.conversation_messages(session_id, created_at);
create index if not exists conversation_messages_owner_created_idx
  on public.conversation_messages(owner_user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Agentic execution + permission layer.
-- ---------------------------------------------------------------------------
create table if not exists public.agent_tasks (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  session_id uuid references public.conversation_sessions(id) on delete set null,
  kind text not null default 'delegation',
  title text not null,
  status text not null default 'queued' check (status in ('queued', 'planning', 'requires_confirmation', 'running', 'succeeded', 'failed', 'cancelled')),
  risk_level text not null default 'low' check (risk_level in ('low', 'medium', 'high')),
  confirmation_required boolean not null default false,
  confirmed_at timestamptz,
  input jsonb not null default '{}'::jsonb,
  result jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists agent_tasks_owner_status_idx
  on public.agent_tasks(owner_user_id, status, created_at desc);

drop trigger if exists agent_tasks_set_updated_at on public.agent_tasks;
create trigger agent_tasks_set_updated_at
  before update on public.agent_tasks
  for each row execute function private.set_updated_at();

create table if not exists public.agent_task_events (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.agent_tasks(id) on delete cascade,
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists agent_task_events_task_created_idx
  on public.agent_task_events(task_id, created_at);

create table if not exists public.delegation_permissions (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  permission_key text not null,
  label text not null,
  status text not null default 'requires_confirmation' check (status in ('allowed', 'requires_confirmation', 'disabled')),
  max_amount_cents integer,
  currency text,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_user_id, permission_key)
);

create index if not exists delegation_permissions_owner_idx on public.delegation_permissions(owner_user_id);

drop trigger if exists delegation_permissions_set_updated_at on public.delegation_permissions;
create trigger delegation_permissions_set_updated_at
  before update on public.delegation_permissions
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Memory: SQL-native first, embeddings-ready later.
-- ---------------------------------------------------------------------------
create table if not exists public.memory_items (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  source_device_id uuid references public.user_devices(id) on delete set null,
  source_session_id uuid references public.conversation_sessions(id) on delete set null,
  kind text not null default 'fact' check (kind in ('preference', 'fact', 'instruction', 'episode', 'contact_hint', 'system_action_result')),
  scope text not null default 'private' check (scope in ('private', 'agent', 'session', 'demo')),
  sensitivity text not null default 'personal' check (sensitivity in ('low', 'personal', 'secret')),
  lifecycle text not null default 'durable' check (lifecycle in ('transient', 'durable', 'archived')),
  text text not null check (length(trim(text)) > 0),
  tags text[] not null default '{}'::text[],
  confidence numeric(3,2) not null default 1.00 check (confidence >= 0 and confidence <= 1),
  importance integer not null default 50 check (importance >= 0 and importance <= 100),
  metadata jsonb not null default '{}'::jsonb,
  search_vector tsvector,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists memory_items_owner_created_idx
  on public.memory_items(owner_user_id, created_at desc)
  where deleted_at is null;
create index if not exists memory_items_tags_idx
  on public.memory_items using gin(tags)
  where deleted_at is null;
create index if not exists memory_items_search_idx
  on public.memory_items using gin(search_vector)
  where deleted_at is null;

drop trigger if exists memory_items_set_updated_at on public.memory_items;
create trigger memory_items_set_updated_at
  before update on public.memory_items
  for each row execute function private.set_updated_at();

drop trigger if exists memory_items_refresh_search_vector on public.memory_items;
create trigger memory_items_refresh_search_vector
  before insert or update of text, tags on public.memory_items
  for each row execute function private.memory_items_refresh_search_vector();

create table if not exists public.memory_events (
  id uuid primary key default gen_random_uuid(),
  memory_item_id uuid references public.memory_items(id) on delete set null,
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  event_type text not null check (event_type in ('created', 'updated', 'queried', 'deleted', 'confirmed', 'rejected')),
  actor text not null default 'system' check (actor in ('user', 'assistant', 'system', 'admin')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists memory_events_owner_created_idx
  on public.memory_events(owner_user_id, created_at desc);

create table if not exists public.user_preferences (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.app_users(id) on delete cascade,
  preference_key text not null,
  value jsonb not null,
  source_memory_id uuid references public.memory_items(id) on delete set null,
  confidence numeric(3,2) not null default 1.00 check (confidence >= 0 and confidence <= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_user_id, preference_key)
);

drop trigger if exists user_preferences_set_updated_at on public.user_preferences;
create trigger user_preferences_set_updated_at
  before update on public.user_preferences
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- KILLSIRI landing + governance batch tracking.
-- ---------------------------------------------------------------------------
create table if not exists public.waitlist_signups (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  email_normalized text,
  rebel_name text not null,
  share_code text not null unique,
  governance_power integer not null default 10 check (governance_power >= 0),
  manifesto_shared boolean not null default false,
  referred_by text,
  edition text not null default 'first_batch',
  batch_limit integer not null default 500,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(email_normalized)
);

create index if not exists waitlist_share_code_idx on public.waitlist_signups(share_code);
create index if not exists waitlist_referred_by_idx on public.waitlist_signups(referred_by);

drop trigger if exists waitlist_signups_set_updated_at on public.waitlist_signups;
create trigger waitlist_signups_set_updated_at
  before update on public.waitlist_signups
  for each row execute function private.set_updated_at();

drop trigger if exists waitlist_signups_refresh_email_normalized on public.waitlist_signups;
create trigger waitlist_signups_refresh_email_normalized
  before insert or update of email on public.waitlist_signups
  for each row execute function private.waitlist_signups_refresh_email_normalized();

create table if not exists public.governance_power_events (
  id uuid primary key default gen_random_uuid(),
  waitlist_signup_id uuid references public.waitlist_signups(id) on delete cascade,
  delta integer not null,
  reason text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists governance_power_events_signup_idx
  on public.governance_power_events(waitlist_signup_id, created_at desc);

create or replace function public.award_referral_power()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_referrer_id uuid;
begin
  if new.referred_by is not null and length(trim(new.referred_by)) > 0 then
    update public.waitlist_signups
      set governance_power = governance_power + 20
      where share_code = new.referred_by
      returning id into v_referrer_id;

    if v_referrer_id is not null then
      insert into public.governance_power_events(waitlist_signup_id, delta, reason, metadata)
      values (v_referrer_id, 20, 'referral', jsonb_build_object('referred_signup_id', new.id));
    end if;
  end if;

  insert into public.governance_power_events(waitlist_signup_id, delta, reason)
  values (new.id, new.governance_power, 'signup');

  return new;
end;
$$;

drop trigger if exists trg_award_referral on public.waitlist_signups;
create trigger trg_award_referral
  after insert on public.waitlist_signups
  for each row execute function public.award_referral_power();

-- ---------------------------------------------------------------------------
-- Helper functions used by RLS and service RPCs.
-- ---------------------------------------------------------------------------
create or replace function private.current_app_user_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id
  from public.app_users
  where auth_user_id = (select auth.uid())
  limit 1;
$$;

create or replace function private.ensure_device(p_device_id text)
returns table(app_user_id uuid, device_row_id uuid)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_device_hash text;
  v_app_user_id uuid;
  v_device_row_id uuid;
begin
  if nullif(trim(coalesce(p_device_id, '')), '') is null then
    raise exception 'device id is required' using errcode = '22023';
  end if;

  v_device_hash := encode(extensions.digest(trim(p_device_id), 'sha256'), 'hex');

  select d.owner_user_id, d.id
    into v_app_user_id, v_device_row_id
  from public.user_devices d
  where d.device_hash = v_device_hash;

  if v_device_row_id is null then
    insert into public.app_users(display_name, metadata)
    values ('GIGI user ' || substring(v_device_hash from 1 for 8), jsonb_build_object('source', 'device-bootstrap'))
    returning id into v_app_user_id;

    begin
      insert into public.user_devices(owner_user_id, device_hash, display_name, platform, trusted, last_seen_at)
      values (v_app_user_id, v_device_hash, 'iPhone', 'ios', true, now())
      returning id into v_device_row_id;
    exception when unique_violation then
      select d.owner_user_id, d.id
        into v_app_user_id, v_device_row_id
      from public.user_devices d
      where d.device_hash = v_device_hash;
    end;
  else
    update public.user_devices
      set last_seen_at = now()
      where id = v_device_row_id;
  end if;

  return query select v_app_user_id, v_device_row_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs: current harness memory API compatibility.
-- ---------------------------------------------------------------------------
create or replace function public.gigi_memory_put(
  p_device_id text,
  p_text text,
  p_tags text[] default '{}'::text[],
  p_kind text default 'fact',
  p_scope text default 'private'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ctx record;
  v_item public.memory_items%rowtype;
begin
  if nullif(trim(coalesce(p_text, '')), '') is null then
    raise exception 'memory text is required' using errcode = '22023';
  end if;

  select * into v_ctx from private.ensure_device(p_device_id);

  insert into public.memory_items(owner_user_id, source_device_id, kind, scope, text, tags)
  values (v_ctx.app_user_id, v_ctx.device_row_id, coalesce(p_kind, 'fact'), coalesce(p_scope, 'private'), trim(p_text), coalesce(p_tags, '{}'::text[]))
  returning * into v_item;

  insert into public.memory_events(memory_item_id, owner_user_id, event_type, actor)
  values (v_item.id, v_item.owner_user_id, 'created', 'user');

  return jsonb_build_object(
    'id', v_item.id::text,
    'userId', p_device_id,
    'text', v_item.text,
    'tags', v_item.tags,
    'ts', (extract(epoch from v_item.created_at) * 1000)::bigint
  );
end;
$$;

create or replace function public.gigi_memory_query(
  p_device_id text,
  p_query text default '',
  p_limit integer default 10
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ctx record;
  v_query text := trim(coalesce(p_query, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 50));
  v_tsquery tsquery;
  v_results jsonb;
begin
  select * into v_ctx from private.ensure_device(p_device_id);

  if v_query = '' then
    select coalesce(jsonb_agg(item order by item_created_at desc), '[]'::jsonb)
      into v_results
    from (
      select
        jsonb_build_object(
          'id', mi.id::text,
          'userId', p_device_id,
          'text', mi.text,
          'tags', mi.tags,
          'ts', (extract(epoch from mi.created_at) * 1000)::bigint,
          'score', 0
        ) as item,
        mi.created_at as item_created_at
      from public.memory_items mi
      where mi.owner_user_id = v_ctx.app_user_id
        and mi.deleted_at is null
      order by mi.created_at desc
      limit v_limit
    ) recent;
  else
    v_tsquery := websearch_to_tsquery('simple', v_query);

    select coalesce(jsonb_agg(item order by score desc, item_created_at desc), '[]'::jsonb)
      into v_results
    from (
      select
        jsonb_build_object(
          'id', mi.id::text,
          'userId', p_device_id,
          'text', mi.text,
          'tags', mi.tags,
          'ts', (extract(epoch from mi.created_at) * 1000)::bigint,
          'score', ts_rank_cd(mi.search_vector, v_tsquery)
        ) as item,
        ts_rank_cd(mi.search_vector, v_tsquery) as score,
        mi.created_at as item_created_at
      from public.memory_items mi
      where mi.owner_user_id = v_ctx.app_user_id
        and mi.deleted_at is null
        and mi.search_vector @@ v_tsquery
      order by score desc, mi.created_at desc
      limit v_limit
    ) ranked;
  end if;

  insert into public.memory_events(owner_user_id, event_type, actor, payload)
  values (v_ctx.app_user_id, 'queried', 'assistant', jsonb_build_object('query', v_query, 'limit', v_limit));

  return coalesce(v_results, '[]'::jsonb);
end;
$$;

create or replace function public.gigi_memory_delete(p_device_id text, p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ctx record;
  v_deleted_id uuid;
begin
  select * into v_ctx from private.ensure_device(p_device_id);

  update public.memory_items
    set deleted_at = now()
    where id = p_id
      and owner_user_id = v_ctx.app_user_id
      and deleted_at is null
    returning id into v_deleted_id;

  if v_deleted_id is not null then
    insert into public.memory_events(memory_item_id, owner_user_id, event_type, actor)
    values (v_deleted_id, v_ctx.app_user_id, 'deleted', 'user');
  end if;

  return v_deleted_id is not null;
end;
$$;

create or replace function public.gigi_memory_all(p_device_id text, p_limit integer default 1000)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ctx record;
  v_limit integer := greatest(1, least(coalesce(p_limit, 1000), 5000));
  v_results jsonb;
begin
  select * into v_ctx from private.ensure_device(p_device_id);

  select coalesce(jsonb_agg(item order by item_created_at desc), '[]'::jsonb)
    into v_results
  from (
    select
      jsonb_build_object(
        'id', mi.id::text,
        'userId', p_device_id,
        'text', mi.text,
        'tags', mi.tags,
        'ts', (extract(epoch from mi.created_at) * 1000)::bigint
      ) as item,
      mi.created_at as item_created_at
    from public.memory_items mi
    where mi.owner_user_id = v_ctx.app_user_id
      and mi.deleted_at is null
    order by mi.created_at desc
    limit v_limit
  ) all_items;

  return coalesce(v_results, '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs: KILLSIRI landing. No anon table reads; anon gets only controlled funcs.
-- ---------------------------------------------------------------------------
create or replace function public.killsiri_join_waitlist(
  p_email text,
  p_rebel_name text,
  p_share_code text,
  p_referred_by text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_signup public.waitlist_signups%rowtype;
begin
  if nullif(trim(coalesce(p_email, '')), '') is null then
    raise exception 'email is required' using errcode = '22023';
  end if;
  if p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email' using errcode = '22023';
  end if;

  insert into public.waitlist_signups(email, rebel_name, share_code, referred_by)
  values (lower(trim(p_email)), trim(coalesce(p_rebel_name, 'REBEL')), upper(trim(p_share_code)), nullif(upper(trim(coalesce(p_referred_by, ''))), ''))
  on conflict (email_normalized) do update
    set updated_at = now()
  returning * into v_signup;

  return jsonb_build_object(
    'id', v_signup.id::text,
    'email', v_signup.email,
    'rebel_name', v_signup.rebel_name,
    'share_code', v_signup.share_code,
    'governance_power', v_signup.governance_power,
    'manifesto_shared', v_signup.manifesto_shared,
    'referred_by', v_signup.referred_by,
    'edition', v_signup.edition,
    'batch_limit', v_signup.batch_limit,
    'created_at', v_signup.created_at
  );
end;
$$;

create or replace function public.killsiri_rebel_count()
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*) from public.waitlist_signups;
$$;

-- ---------------------------------------------------------------------------
-- RLS: deny by default, authenticated users see only own rows, service_role uses
-- backend key/RPCs. Public landing uses RPCs only.
-- ---------------------------------------------------------------------------
alter table public.app_users enable row level security;
alter table public.user_devices enable row level security;
alter table public.channel_identities enable row level security;
alter table public.external_accounts enable row level security;
alter table public.conversation_sessions enable row level security;
alter table public.conversation_messages enable row level security;
alter table public.agent_tasks enable row level security;
alter table public.agent_task_events enable row level security;
alter table public.delegation_permissions enable row level security;
alter table public.memory_items enable row level security;
alter table public.memory_events enable row level security;
alter table public.user_preferences enable row level security;
alter table public.waitlist_signups enable row level security;
alter table public.governance_power_events enable row level security;

-- Drop/recreate policies so reruns stay deterministic.
drop policy if exists app_users_own_select on public.app_users;
drop policy if exists app_users_own_update on public.app_users;
create policy app_users_own_select on public.app_users
  for select to authenticated
  using (id = (select private.current_app_user_id()));
create policy app_users_own_update on public.app_users
  for update to authenticated
  using (id = (select private.current_app_user_id()))
  with check (id = (select private.current_app_user_id()));

-- Same owner policy for all owner_user_id tables.
drop policy if exists user_devices_own_all on public.user_devices;
create policy user_devices_own_all on public.user_devices
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists channel_identities_own_all on public.channel_identities;
create policy channel_identities_own_all on public.channel_identities
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists external_accounts_own_all on public.external_accounts;
create policy external_accounts_own_all on public.external_accounts
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists conversation_sessions_own_all on public.conversation_sessions;
create policy conversation_sessions_own_all on public.conversation_sessions
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists conversation_messages_own_all on public.conversation_messages;
create policy conversation_messages_own_all on public.conversation_messages
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists agent_tasks_own_all on public.agent_tasks;
create policy agent_tasks_own_all on public.agent_tasks
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists agent_task_events_own_all on public.agent_task_events;
create policy agent_task_events_own_all on public.agent_task_events
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists delegation_permissions_own_all on public.delegation_permissions;
create policy delegation_permissions_own_all on public.delegation_permissions
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists memory_items_own_all on public.memory_items;
create policy memory_items_own_all on public.memory_items
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

drop policy if exists memory_events_own_select on public.memory_events;
create policy memory_events_own_select on public.memory_events
  for select to authenticated
  using (owner_user_id = (select private.current_app_user_id()));

drop policy if exists user_preferences_own_all on public.user_preferences;
create policy user_preferences_own_all on public.user_preferences
  for all to authenticated
  using (owner_user_id = (select private.current_app_user_id()))
  with check (owner_user_id = (select private.current_app_user_id()));

-- No anon table policies for waitlist/governance. RPC only.

-- Grants: least-privilege table surface + explicit RPC surface.
revoke all on public.waitlist_signups from anon;
revoke all on public.governance_power_events from anon;

grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

revoke all on function public.gigi_memory_put(text, text, text[], text, text) from public;
revoke all on function public.gigi_memory_query(text, text, integer) from public;
revoke all on function public.gigi_memory_delete(text, uuid) from public;
revoke all on function public.gigi_memory_all(text, integer) from public;
revoke all on function public.killsiri_join_waitlist(text, text, text, text) from public;
revoke all on function public.killsiri_rebel_count() from public;

grant execute on function public.gigi_memory_put(text, text, text[], text, text) to service_role;
grant execute on function public.gigi_memory_query(text, text, integer) to service_role;
grant execute on function public.gigi_memory_delete(text, uuid) to service_role;
grant execute on function public.gigi_memory_all(text, integer) to service_role;

grant execute on function public.killsiri_join_waitlist(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.killsiri_rebel_count() to anon, authenticated, service_role;

grant execute on function private.current_app_user_id() to authenticated, service_role;
grant execute on function private.ensure_device(text) to service_role;

commit;
