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

-- Answer history: every change to atb_rsvp is logged by a trigger; managers read it, nobody writes it directly.
alter table public.atb_polls add column if not exists kickoff timestamptz;
create table if not exists public.atb_rsvp_log (
  id bigint generated always as identity primary key,
  poll_id uuid not null references public.atb_polls(id) on delete cascade,
  player_id text not null, status text not null check (status in ('in','out','cleared')), prev_status text,
  at timestamptz not null default now());
alter table public.atb_rsvp_log enable row level security;
create policy "atb rsvp log team read" on public.atb_rsvp_log for select to authenticated
  using (exists (select 1 from public.atb_polls p where p.id = poll_id and private.atb_is_team(p.owner)));
-- trigger function private.atb_log_rsvp() (security definer) inserts on insert/update(status change)/delete of atb_rsvp

-- Voting PINs + vote alerts (see migration atb_vote_pins_and_notify):
-- atb_player_pins (bcrypt PIN per player, 5 wrong tries = 1 h lock), public.atb_vote(poll, player, status, pin) is the only way to answer,
-- public.atb_pin_status(poll, player); direct insert/update on atb_rsvp revoked for anon.
-- atb_notify (per-manager ntfy.sh topic + optional email); trigger on atb_rsvp_log posts to https://ntfy.sh via pg_net (schema extensions).

-- Waitlist + auto-open (migration atb_waitlist_and_auto_open): atb_polls.max_players; atb_vote keeps a player's queue position on repeat taps;
-- pg_cron job 'atb-auto-open' (Mon 03:00 UTC = Sunday evening Alberta) runs private.atb_auto_open() for teams with settings.autoLink.

-- Player sign-in (migration atb_player_logins): private.atb_player_sessions (sha256 token hashes, 180-day sliding expiry),
-- RPCs atb_player_roster / atb_player_login / atb_player_logout / atb_player_data / atb_player_vote / atb_player_setpin (anon-callable, security definer).
-- atb_player_data returns only the signed-in player's profile; other players' ratings are never returned, own ratings only when settings.playerRatings.

-- Security hardening (migration atb_security_hardening): private.atb_teams allow-list; atb_is_team requires a registered team;
-- voting page reads a single link via public.atb_poll_view(uuid) (anon open-poll/rsvp SELECT policies removed);
-- PINs 4-6 digits via private.atb_pin_check: 5 wrong = 1 h lock, 10 = 24 h, >30 team-wide wrong/24 h = 24 h lock per wrong try, ntfy alerts.
-- Tournaments: atb_polls.kind ('match'|'tournament') + tournament id; docs cols 'tournaments' and 'gear'.

-- Tournament visibility (applied as migration atb_tournament_visibility):
-- private.atb_player_payload only returns tournaments with status <> 'draft' AND
--   see = 'club' (default), or see = 'squad' and the player is in data->'squad',
--   or see = 'pick' and the player is in data->'seeIds'. seeIds is stripped from the payload.
-- Settings payload also carries psAuto (auto-award PlayStyles from ratings).

-- Club crests not bundled in icons/crests/ (MLS, Saudi, Argentine, Brazilian, Indian clubs) are copied into the
-- public storage bucket 'crests' as <id>.png (no write policies: only the service role can change them).

-- atb_player_pin_state(team, player) -> 'set' | 'none' | 'blocked' | 'unknown': lets the sign-in screen offer "Create your PIN".

-- PIN setup mode: settings.playerSetup=true with playerLogin=false lists names (atb_player_roster mode 'setup') and allows
-- atb_player_create_pin(team, player, pin) to create a first PIN only; the portal (atb_player_login) stays closed.

-- Support (Ko-fi) popup analytics: private.atb_tip_events (not exposed). Written by atb_tip_log (player token) and
-- atb_tip_log_mgr (managers; admin's own clicks skipped). Read only via atb_tip_stats(), which returns null unless the admin calls it.

-- Portal access: private.atb_portal_ok(owner, player) = playerLogin on, not noLogin, and
-- (settings.portalAll != false ? player.portal != false : player.portal = true). Enforced in atb_session (all token calls),
-- atb_player_data ('paused') and atb_player_login (PIN created/checked but no session). Roster returns 'ok' per player.

-- Admin alerts: atb_notify.god_mgr / god_pl (admin's own row, member = team). Triggers atb_god_mgr (atb_activity) and
-- atb_god_pl (atb_player_activity) push major actions to the admin's ntfy topic via private.atb_god_push; private.atb_major
-- filters out page views/opens; repeats within 2 minutes are skipped; the admin's own actions are skipped.

-- Admin alerts v2: every manager action counts (atb_major('mgr',…) = true). Repeat pushes are skipped for 2 min
-- (same action and detail), and for 30 min for 'Opened app'. The client logs 'Signed in' on a password sign-in, and a
-- "what changed" detail for player, match, settings, tournament and equipment edits.

-- POTM vote window: match day until end of the 2nd day after (atb_player_potm closes at date - 2; payload reveals pvote after that).

-- Finalized teams: atb_docs col='fixtures' (id = date). Player payload adds 'fixtures' (date >= today) and only sends matches dated today or earlier.

-- Version gate: private.atb_cfg(min_build); atb_docs insert/update/delete also need private.atb_build_ok() (build number sent in x-client-info as atb/yyyymmddHHMM).
-- RPCs: atb_min_build(), atb_set_min_build(text) (admin). Player sessions end after 1 hour without use (private.atb_session).
-- Player sign-in pushes come from 'Signed in on' (device) sent by the app right after a PIN sign-in.

-- Player profile: public.atb_player_profile(token, jsonb) -> data.prof {nick,bestPos,card,ability,ps[<=5],favPlayer,favMate,boots,stadium,dreamNo}; settings.playerProfile (default on).
-- Photo requests: public.atb_player_photo(token, dataURL|'') -> data.photoReq {img,at}; managers approve in Squad.
-- Chemistry: public.atb_chem(team, rater, ratee, score 1-5), RLS read for the team; public.atb_player_chem(token, ratee, score 0-5). Payload adds players[].prof and chem (my ratings).

-- Dream teams: public.atb_player_dreams(token, jsonb array <=5, <=30KB) -> data.dreams (only the player and managers see it). Weekly team captains: match/fixture team.cap.
-- HD photos: payload players[].pv = left(md5(photo),10); public.atb_player_photos(token, ids[]) -> {id: photo} (max 40 ids). Client caches by pv in IndexedDB 'atb_hd'.
-- settings.squadRatings (default off): payload sends other players' base/baseN/skills/wf/foot/height/ps and full match ratings, showRatings=true. prof.favMate is never sent for other players.
-- Player photo v2: public.atb_player_photo2(token,img,cut,thumb) -> 'ok' (photoReq {img,cut,thumb,at}) or 'live' when settings.photoAuto. Payload settings adds announce {text,at}, photoAuto.
-- Manager ↔ own player: private.atb_mgr_links(uid,owner,player_id); public.atb_mgr_link(token) (authenticated; set on PIN sign-in / player-mode boot); public.atb_mgr_player_token() issues a player session for the linked player (no PIN).
-- atb_player_profile: card accepts any ^[a-z]{2,12}$ key (client renders known designs: 18 special designs + legacy colours).
-- Feedback: public.atb_feedback (RLS read: team owner only); atb_player_feedback(token,area,rating,body,usage) (5/day, logs 'Sent feedback'); atb_mgr_feedback(team,area,rating,body). Expenses: atb_docs col 'expenses' (managers only; not in player payload).

-- 2026-10-02: player payload also sends 'starCard' (manager-chosen card design for star players)
--   patched in private.atb_player_payload: 'star', x.data->'star', 'starCard', x.data->'starCard',

-- 2026-10-02: public Storage bucket 'stars' (ready star cut-outs + index.json); only the admin email can upload
--   policies on storage.objects: stars_admin_insert / stars_admin_update / stars_admin_select

-- 2026-10-02: player payload sends 'fc' (manager attribute overrides) with the shared squad ratings
