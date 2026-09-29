-- Airdrie Team Builder: one table, one row per document, private to each signed-in user.
create table if not exists public.atb_docs (
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  col text not null,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (owner, col, id)
);
alter table public.atb_docs enable row level security;
create policy "atb own rows select" on public.atb_docs for select to authenticated using (owner = (select auth.uid()));
create policy "atb own rows insert" on public.atb_docs for insert to authenticated with check (owner = (select auth.uid()));
create policy "atb own rows update" on public.atb_docs for update to authenticated using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
create policy "atb own rows delete" on public.atb_docs for delete to authenticated using (owner = (select auth.uid()));
alter table public.atb_docs replica identity full;
alter publication supabase_realtime add table public.atb_docs;

-- Availability links: players answer "I'm in" without signing in; they can only see names on an open link.
create table if not exists public.atb_polls (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  match_date date not null, title text not null default 'Saturday Soccer', time_label text,
  players jsonb not null, open boolean not null default true, created_at timestamptz not null default now());
create table if not exists public.atb_rsvp (
  poll_id uuid not null references public.atb_polls(id) on delete cascade, player_id text not null,
  status text not null check (status in ('in','out')), updated_at timestamptz not null default now(),
  primary key (poll_id, player_id));
alter table public.atb_polls enable row level security;
alter table public.atb_rsvp enable row level security;
create policy "atb polls owner all" on public.atb_polls for all to authenticated using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
create policy "atb polls read open" on public.atb_polls for select to anon, authenticated using (open);
create policy "atb rsvp read open" on public.atb_rsvp for select to anon, authenticated using (exists (select 1 from public.atb_polls p where p.id = poll_id and (p.open or p.owner = (select auth.uid()))));
create policy "atb rsvp insert open" on public.atb_rsvp for insert to anon, authenticated with check (exists (select 1 from public.atb_polls p where p.id = poll_id and p.open and p.players @> jsonb_build_array(jsonb_build_object('id', player_id))));
create policy "atb rsvp update open" on public.atb_rsvp for update to anon, authenticated using (exists (select 1 from public.atb_polls p where p.id = poll_id and p.open)) with check (exists (select 1 from public.atb_polls p where p.id = poll_id and p.open and p.players @> jsonb_build_array(jsonb_build_object('id', player_id))));
create policy "atb rsvp owner delete" on public.atb_rsvp for delete to authenticated using (exists (select 1 from public.atb_polls p where p.id = poll_id and p.owner = (select auth.uid())));
grant select on public.atb_polls to anon;
grant select, insert, update on public.atb_rsvp to anon;

-- Managers share the admin's team. Accounts are created only by the atb-managers edge function (admin email check inside).
create table if not exists public.atb_members (
  team_owner uuid not null references auth.users(id) on delete cascade,
  member uuid not null references auth.users(id) on delete cascade,
  username text not null, created_at timestamptz not null default now(),
  primary key (team_owner, member), unique (member));
alter table public.atb_members enable row level security;
create policy "atb members read" on public.atb_members for select to authenticated using (team_owner = (select auth.uid()) or member = (select auth.uid()));
create schema if not exists private;
create or replace function private.atb_is_team(o uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select o = auth.uid() or exists (select 1 from public.atb_members m where m.team_owner = o and m.member = auth.uid()) $$;
-- then replace the owner-only policies on atb_docs / atb_polls / atb_rsvp with private.atb_is_team(owner) checks
