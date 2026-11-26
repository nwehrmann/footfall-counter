-- ILC MVP update 6: Experiments (reusable tap counters), with the BSL latte sign test set up.
-- Run once in Supabase → SQL Editor → New query → Run. Safe to run again; keeps all existing data.

create table if not exists public.experiments (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  categories jsonb not null default '[]'::jsonb,
  compare text[],
  default_location text,
  created_by text,
  created_at timestamptz not null default now()
);

create table if not exists public.exp_sessions (
  id uuid primary key default gen_random_uuid(),
  experiment_id uuid not null references public.experiments(id) on delete cascade,
  session_date date not null,
  start_time text,
  end_time text,
  location text,
  observer text,
  notes text,
  locked boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists exp_sessions_exp on public.exp_sessions (experiment_id, session_date);

create table if not exists public.exp_taps (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.exp_sessions(id) on delete cascade,
  category text not null,
  delta integer not null,
  source text not null default 'tap' check (source in ('tap', 'edit')),
  observer text,
  at timestamptz not null default now()
);
create index if not exists exp_taps_session on public.exp_taps (session_id, at);

alter table public.experiments enable row level security;
alter table public.exp_sessions enable row level security;
alter table public.exp_taps enable row level security;

drop policy if exists "read experiments" on public.experiments;
drop policy if exists "add experiments" on public.experiments;
drop policy if exists "edit experiments" on public.experiments;
create policy "read experiments" on public.experiments for select to anon, authenticated using (true);
create policy "add experiments"  on public.experiments for insert to anon, authenticated with check (true);
create policy "edit experiments" on public.experiments for update to anon, authenticated using (true) with check (true);

drop policy if exists "read sessions" on public.exp_sessions;
drop policy if exists "add sessions" on public.exp_sessions;
drop policy if exists "edit sessions" on public.exp_sessions;
drop policy if exists "delete sessions" on public.exp_sessions;
create policy "read sessions"   on public.exp_sessions for select to anon, authenticated using (true);
create policy "add sessions"    on public.exp_sessions for insert to anon, authenticated with check (true);
create policy "edit sessions"   on public.exp_sessions for update to anon, authenticated using (true) with check (true);
create policy "delete sessions" on public.exp_sessions for delete to anon, authenticated using (not locked);

-- taps can be added (never edited), and only while their session is unlocked
drop policy if exists "read exp taps" on public.exp_taps;
drop policy if exists "add exp taps" on public.exp_taps;
create policy "read exp taps" on public.exp_taps for select to anon, authenticated using (true);
create policy "add exp taps"  on public.exp_taps for insert to anon, authenticated
  with check (exists (select 1 from public.exp_sessions s where s.id = session_id and not s.locked));

grant select, insert, update on public.experiments to anon, authenticated;
grant select, insert, update, delete on public.exp_sessions to anon, authenticated;
grant select, insert on public.exp_taps to anon, authenticated;

-- the BSL latte sign test (only added once)
insert into public.experiments (id, name, description, categories, compare, default_location, created_by)
values (
  '5b1a7c1e-0b5f-4c2e-9d3a-6f0e1a2b3c4d',
  'BSL latte sign test',
  'Sign experiment with Lester. Count everyone who stops to look at the sign, which option they choose, and who actually tries to sign "latte" in BSL.',
  '[{"key":"stopped","label":"Stopped to see the sign"},{"key":"a","label":"Chose option A"},{"key":"b","label":"Chose option B"},{"key":"tried","label":"Tried to sign \"latte\" in BSL"}]'::jsonb,
  array['a','b'],
  'LSE Library — John Watkins Plaza',
  'Nathan'
) on conflict (id) do nothing;

do $$ begin alter publication supabase_realtime add table public.experiments; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.exp_sessions; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.exp_taps; exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
