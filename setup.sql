-- Library footfall counter: run once in Supabase → SQL Editor → New query → Run

create table if not exists public.slots (
  id uuid primary key default gen_random_uuid(),
  slot_date date not null,
  start_time text not null,
  end_time text,
  place text,
  in_count integer not null default 0 check (in_count >= 0),
  out_count integer not null default 0 check (out_count >= 0),
  past_count integer not null default 0 check (past_count >= 0),
  created_at timestamptz not null default now()
);

alter table public.slots enable row level security;

drop policy if exists "anyone can read" on public.slots;
drop policy if exists "anyone can add" on public.slots;
drop policy if exists "anyone can edit" on public.slots;
drop policy if exists "anyone can delete" on public.slots;
create policy "anyone can read"   on public.slots for select to anon, authenticated using (true);
create policy "anyone can add"    on public.slots for insert to anon, authenticated with check (true);
create policy "anyone can edit"   on public.slots for update to anon, authenticated using (true) with check (true);
create policy "anyone can delete" on public.slots for delete to anon, authenticated using (true);

grant select, insert, update, delete on public.slots to anon, authenticated;

-- +1 / -1 in one step on the server, so two people tapping at once never overwrite each other
create or replace function public.bump(p_id uuid, p_field text, p_delta integer)
returns public.slots
language plpgsql
security invoker
set search_path = public
as $$
declare r public.slots;
begin
  if p_delta not in (-1, 1) then raise exception 'delta must be 1 or -1'; end if;
  if p_field = 'in' then
    update public.slots set in_count = greatest(0, in_count + p_delta) where id = p_id returning * into r;
  elsif p_field = 'out' then
    update public.slots set out_count = greatest(0, out_count + p_delta) where id = p_id returning * into r;
  elsif p_field = 'past' then
    update public.slots set past_count = greatest(0, past_count + p_delta) where id = p_id returning * into r;
  else
    raise exception 'unknown field';
  end if;
  return r;
end $$;

grant execute on function public.bump(uuid, text, integer) to anon, authenticated;

-- live updates between phones
do $$ begin
  alter publication supabase_realtime add table public.slots;
exception when duplicate_object then null;
end $$;

-- update 2: lock slots
alter table public.slots add column if not exists locked boolean not null default false;

create or replace function public.bump(p_id uuid, p_field text, p_delta integer)
returns public.slots
language plpgsql
security invoker
set search_path = public
as $$
declare r public.slots;
begin
  if p_delta not in (-1, 1) then raise exception 'delta must be 1 or -1'; end if;
  if p_field = 'in' then
    update public.slots set in_count = greatest(0, in_count + p_delta) where id = p_id and not locked returning * into r;
  elsif p_field = 'out' then
    update public.slots set out_count = greatest(0, out_count + p_delta) where id = p_id and not locked returning * into r;
  elsif p_field = 'past' then
    update public.slots set past_count = greatest(0, past_count + p_delta) where id = p_id and not locked returning * into r;
  else
    raise exception 'unknown field';
  end if;
  if r.id is null then raise exception 'This slot is locked. Tap Edit to unlock it first.'; end if;
  return r;
end $$;

-- update 3: tap log

create table if not exists public.taps (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.slots(id) on delete cascade,
  field text not null check (field in ('in', 'out', 'past')),
  delta integer not null,
  source text not null default 'tap' check (source in ('tap', 'paper', 'edit')),
  at timestamptz not null default now()
);
create index if not exists taps_slot_at on public.taps (slot_id, at);

alter table public.taps enable row level security;
drop policy if exists "anyone can read taps" on public.taps;
drop policy if exists "anyone can add taps" on public.taps;
create policy "anyone can read taps" on public.taps for select to anon, authenticated using (true);
create policy "anyone can add taps"  on public.taps for insert to anon, authenticated with check (true);
-- no update/delete policy: the log can't be rewritten from the app (it is removed only when its slot is deleted)
grant select, insert on public.taps to anon, authenticated;

-- +1 / -1 now also writes a timestamped row to the tap log, in the same step
create or replace function public.bump(p_id uuid, p_field text, p_delta integer)
returns public.slots
language plpgsql
security invoker
set search_path = public
as $$
declare r public.slots;
begin
  if p_delta not in (-1, 1) then raise exception 'delta must be 1 or -1'; end if;
  if p_field = 'in' then
    update public.slots set in_count = in_count + p_delta where id = p_id and not locked and in_count + p_delta >= 0 returning * into r;
  elsif p_field = 'out' then
    update public.slots set out_count = out_count + p_delta where id = p_id and not locked and out_count + p_delta >= 0 returning * into r;
  elsif p_field = 'past' then
    update public.slots set past_count = past_count + p_delta where id = p_id and not locked and past_count + p_delta >= 0 returning * into r;
  else
    raise exception 'unknown field';
  end if;
  if r.id is null then
    select * into r from public.slots where id = p_id;
    if r.id is null then raise exception 'Slot not found'; end if;
    if r.locked then raise exception 'This slot is locked. Tap Edit to unlock it first.'; end if;
    return r; -- count already at 0, nothing to subtract
  end if;
  insert into public.taps (slot_id, field, delta, source) values (p_id, p_field, p_delta, 'tap');
  return r;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.taps;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';
