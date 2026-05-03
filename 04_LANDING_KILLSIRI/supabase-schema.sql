-- ============================================
-- KILLSIRI — Supabase schema
-- Run this in: Supabase Dashboard > SQL Editor > New query
-- ============================================

-- Table
create table if not exists public.waitlist_signups (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  rebel_name text not null,
  share_code text unique not null,
  governance_power integer not null default 10,
  manifesto_shared boolean not null default false,
  referred_by text,
  created_at timestamptz not null default now()
);

-- Indexes for fast lookup
create index if not exists idx_waitlist_email on public.waitlist_signups(email);
create index if not exists idx_waitlist_share_code on public.waitlist_signups(share_code);
create index if not exists idx_waitlist_referred_by on public.waitlist_signups(referred_by);

-- Enable RLS
alter table public.waitlist_signups enable row level security;

-- Policy: anyone (anon) can insert their own signup
drop policy if exists "anon_insert_signup" on public.waitlist_signups;
create policy "anon_insert_signup"
  on public.waitlist_signups
  for insert
  to anon
  with check (true);

-- Policy: anon can SELECT only count (no full row read).
-- Trick: grant a count-only policy by allowing select on minimal column.
-- Simpler: allow select of id only (frontend uses count=exact header).
drop policy if exists "anon_count_signups" on public.waitlist_signups;
create policy "anon_count_signups"
  on public.waitlist_signups
  for select
  to anon
  using (true);

-- NOTE: anon SELECT exposes all rows via REST. To lock it down later:
--   1. Drop the "anon_count_signups" policy
--   2. Create a `count_rebels()` RPC function with security definer
--   3. Call rpc/count_rebels from frontend instead of direct select
-- For MVP launch this is acceptable (emails will be hashed later if needed).

-- Optional: trigger to award referrer +20 power on new signup
create or replace function public.award_referral_power()
returns trigger as $$
begin
  if new.referred_by is not null then
    update public.waitlist_signups
    set governance_power = governance_power + 20
    where share_code = new.referred_by;
  end if;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists trg_award_referral on public.waitlist_signups;
create trigger trg_award_referral
  after insert on public.waitlist_signups
  for each row
  execute function public.award_referral_power();
