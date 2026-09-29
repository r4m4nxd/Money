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
