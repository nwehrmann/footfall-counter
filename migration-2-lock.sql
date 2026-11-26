-- Footfall counter update 2: lock slots. Run once in Supabase → SQL Editor → New query → Run
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
