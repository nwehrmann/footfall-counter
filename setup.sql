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
