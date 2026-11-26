-- Footfall counter update 4: who counted each slot. Run once in Supabase → SQL Editor → New query → Run
alter table public.slots add column if not exists observer text;
alter table public.slots add column if not exists slot_code text;
notify pgrst, 'reload schema';
