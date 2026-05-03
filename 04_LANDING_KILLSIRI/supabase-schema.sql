-- ============================================
-- KILLSIRI — Supabase waitlist schema
-- Canonical full DB: ../supabase/migrations/202605030001_gigi_core.sql
-- This standalone file only activates the landing waitlist RPCs.
-- Run in: Supabase Dashboard > SQL Editor > New query
-- ============================================

begin;

create schema if not exists extensions;

create extension if not exists pgcrypto with schema extensions;

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

create or replace function public.set_waitlist_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists waitlist_signups_set_updated_at on public.waitlist_signups;
create trigger waitlist_signups_set_updated_at
  before update on public.waitlist_signups
  for each row execute function public.set_waitlist_updated_at();

-- GENERATED with lower(trim(email)) can fail immutability checks on hosted Postgres.
create or replace function public.refresh_waitlist_email_normalized()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.email_normalized := lower(trim(new.email));
  return new;
end;
$$;

drop trigger if exists waitlist_signups_refresh_email_normalized on public.waitlist_signups;
create trigger waitlist_signups_refresh_email_normalized
  before insert or update of email on public.waitlist_signups
  for each row execute function public.refresh_waitlist_email_normalized();

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

alter table public.waitlist_signups enable row level security;
alter table public.governance_power_events enable row level security;

-- No anon table policies: the browser can only execute the two safe RPCs.
revoke all on public.waitlist_signups from anon;
revoke all on public.governance_power_events from anon;

revoke all on function public.killsiri_join_waitlist(text, text, text, text) from public;
revoke all on function public.killsiri_rebel_count() from public;
grant execute on function public.killsiri_join_waitlist(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.killsiri_rebel_count() to anon, authenticated, service_role;

commit;
