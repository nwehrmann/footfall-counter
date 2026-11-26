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

-- update 4: observer and slot ID
alter table public.slots add column if not exists observer text;
alter table public.slots add column if not exists slot_code text;
notify pgrst, 'reload schema';

-- update 5: competitors, café profiles and queue log

create table if not exists public.competitors (
  id text primary key,
  grp text, name text not null, address text,
  owner text, status text default 'Unassigned', notes text,
  ind_fw numeric, ind_latte numeric, conf_fw numeric, conf_latte numeric,
  cup_sizes text, offer text, walk_min numeric, walk_m text,
  order_method text, seating text, accessibility text, positioning text, hours text,
  price_evidence text, research_notes text, sources text, route_url text, research_date date,
  updated_by text, updated_at timestamptz default now(), created_at timestamptz default now()
);

create table if not exists public.queue_obs (
  id uuid primary key default gen_random_uuid(),
  code text,
  competitor_id text not null references public.competitors(id) on update cascade,
  observer text,
  obs_date date not null,
  obs_time time,
  people integer check (people >= 0),
  tills integer check (tills >= 0),
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists queue_obs_comp on public.queue_obs (competitor_id, obs_date);

alter table public.competitors enable row level security;
alter table public.queue_obs enable row level security;
drop policy if exists "read competitors" on public.competitors;
drop policy if exists "add competitors" on public.competitors;
drop policy if exists "edit competitors" on public.competitors;
create policy "read competitors" on public.competitors for select to anon, authenticated using (true);
create policy "add competitors"  on public.competitors for insert to anon, authenticated with check (true);
create policy "edit competitors" on public.competitors for update to anon, authenticated using (true) with check (true);
drop policy if exists "read queue" on public.queue_obs;
drop policy if exists "add queue" on public.queue_obs;
drop policy if exists "edit queue" on public.queue_obs;
drop policy if exists "delete queue" on public.queue_obs;
create policy "read queue"   on public.queue_obs for select to anon, authenticated using (true);
create policy "add queue"    on public.queue_obs for insert to anon, authenticated with check (true);
create policy "edit queue"   on public.queue_obs for update to anon, authenticated using (true) with check (true);
create policy "delete queue" on public.queue_obs for delete to anon, authenticated using (true);
grant select, insert, update on public.competitors to anon, authenticated;
grant select, insert, update, delete on public.queue_obs to anon, authenticated;

-- the 16 cafés and their desk research (only added if not already there)
insert into public.competitors (id,grp,name,address,owner,status,notes,ind_fw,ind_latte,conf_fw,conf_latte,cup_sizes,offer,walk_min,walk_m,order_method,seating,accessibility,positioning,hours,price_evidence,research_notes,sources,route_url,research_date) values
('C01','On-campus','Beaver''s Brew','Marshall Building, LSE','Rishi','Assigned',null,null,null,null,null,null,'£2 Americano/espresso/tea + croissant/fruit before 09:30 (not latte/flat white); Food Club: 10th hot drink free, 5% points value; 25p paper cup charge.',3,'150–250','Counter / cashier ordering; Food Club app scanned at till (LSE scheme).','Coffee, juices, sandwiches and hot lunch',null,'Campus convenience','Mon–Fri 08:30–17:30','£3.40 regular hot drink catering voucher, excl. VAT; not a retail flat white/latte quote.','Actual drink prices not published; optional quick menu-board photo.','https://food.lse.ac.uk/story/40924571/a-guide-to-our-food-and-drink-outlets
https://food.lse.ac.uk/story/16625493/early-bird-breakfast-deal-just-ps150
https://food.lse.ac.uk/story/22370706/join-the-lse-food-club
https://food.lse.ac.uk/story/30432617/opening-hours
https://www.lse.ac.uk/lse-information/campus-map?from_serp=1
https://info.lse.ac.uk/staff/services/catering/order-catering
https://food.lse.ac.uk/story/13702322/5-benefits-of-using-a-keepcup','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=Marshall%20Building%2C%20ground%20floor%2C%2044%20Lincoln%27s%20Inn%20Fields%20London&travelmode=walking','2026-11-24'),
('C02','On-campus','Beveridge Café','Centre Building (CBG) lobby, LSE','Lester','Assigned',null,null,null,null,null,null,'£2 Americano/espresso/tea + croissant/fruit before 09:30 (not latte/flat white); Food Club: 10th hot drink free, 5% points value; 25p paper cup charge.',1,'0–75','Counter / cashier ordering; Food Club app scanned at till (LSE scheme).','Coffee, salads, snacks; adjoining study space',null,'Campus convenience','Mon–Fri 08:30–16:30','£3.40 regular hot drink catering voucher, excl. VAT; not a retail flat white/latte quote.','Actual drink prices not published; optional quick menu-board photo.','https://food.lse.ac.uk/story/40924571/a-guide-to-our-food-and-drink-outlets
https://food.lse.ac.uk/story/16625493/early-bird-breakfast-deal-just-ps150
https://food.lse.ac.uk/story/22370706/join-the-lse-food-club
https://food.lse.ac.uk/story/30432617/opening-hours
https://food.lse.ac.uk/story/28204865/where-to-find-a-great-brew-on-campus
https://www.lse.ac.uk/lse-information/campus-map?from_serp=1
https://info.lse.ac.uk/staff/services/catering/order-catering
https://food.lse.ac.uk/story/13702322/5-benefits-of-using-a-keepcup','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=Centre%20Building%2C%20ground%20floor%2C%20Houghton%20Street%20London&travelmode=walking','2026-11-24'),
('C03','National chain','Blank Street','80 Kingsway, London WC2B 6AG','Rishi','Assigned',null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null),
('C04','National chain','Caffè Nero','7b Kingsway, London WC2B 6XG','Kerem','Assigned',null,3.75,3.75,null,null,null,'10% student offer listed on Student Beans; loyalty stamps',5,'350–500',null,'Italian-style coffee, sandwiches and cakes',null,'Chain / convenience',null,'UK in-store benchmark, 6 Sep 2026: regular latte and flat white £3.75 each. Other-branch delivery £4.55 / £4.45. Verify branch.','77D Kingsway based on food hygiene listing; verify current branch operation. Comparable delivery prices from Theobalds Road. Desk research lists the branch at: 77D Kingsway, WC2B 6SR.','https://ratings.food.gov.uk/business/424716
https://www.caffenero.com/uk/help
https://www.studentbeans.com/student-discount/uk/caffe-nero
https://www.ubereats.com/gb/brand-city/london-eng/caffe-nero
https://www.allinlondon.co.uk/directory/cafes-tea-rooms/25050-caffe-nero
https://deliveroo.co.uk/menu/london/bloomsbury/367-caffe-nero-theobalds-rd
https://www.ubereats.com/gb/store/caffe-nero-spring-st/As32N8JORqmfyPgI13eU8g
https://www.caffenero.com/uk/menu/coffee
https://menuverse.uk/caffe-nero-menu/','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=77D%20Kingsway%2C%20WC2B%206SR%20London&travelmode=walking','2026-11-24'),
('C05','National chain','Costa Coffee','Kean House, London WC2B 6UN',null,'Unassigned',null,4.35,3.95,null,null,'Latte small/medium/large offered by chain; exact branch volumes not verified.','Costa Club: buy 10 crafted drinks, get 1 free; with reusable cup, buy 5, get 1 free (terms apply).',3,'150–250','Counter service; Costa app order-ahead advertised; delivery listing.','Coffee, sandwiches, cakes and snacks','Disabled toilets listed by Costa; visual ordering not verified.','Chain / convenience',null,'UK in-store benchmark, 3 Sep 2026: flat white £4.35, latte small £3.95 / medium £4.40. Kingsway delivery £4.55 / £4.70; central London takeaway flat white reported £4.70 in July 2026. Verify branch.','Branch-specific delivery listing; not an in-store quote. Desk research lists the branch at: 9–11 Kingsway, WC2B 6UN.','https://www.ubereats.com/gb/store/costa-coffee-london-kingsway/BGKsHUIAVK2gdAEB_V1ofA
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://deliveroo.co.uk/menu/london/covent-garden/43026700-costa-coffee-london-kingsway
https://www.costa.co.uk/stores/london-kingsway
https://www.costa.co.uk/costa-club/how-to-guides
https://www.costa.co.uk/terms-and-conditions
https://menuverse.uk/costa-coffee-menu/
https://www.theguardian.com/food/2026/jul/13/coffee-industry-inflationary-pressures-wage-tax-rises-uk','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=9%E2%80%9311%20Kingsway%2C%20WC2B%206UN%20London&travelmode=walking','2026-11-24'),
('C06','On-campus','Garrick','Garrick Building, Basement, LSE',null,'Unassigned',null,null,null,null,null,null,'Free croissant with coffee before 10:30; £4.50 meal deal; Food Club: 10th hot drink free, 5% points value; 25p paper cup charge.',2,'75–150','Counter / cashier ordering; Food Club app scanned at till (LSE scheme).','Ground-floor café; drinks, meal deals and food',null,'Campus convenience / quick lunch','Mon–Fri 08:00–17:00','£3.40 regular hot drink catering voucher, excl. VAT; not a retail flat white/latte quote.','Actual drink prices not published; optional quick menu-board photo. Desk research lists the branch at: Columbia House, Aldwych.','https://food.lse.ac.uk/story/40924571/a-guide-to-our-food-and-drink-outlets
https://food.lse.ac.uk/story/16625493/early-bird-breakfast-deal-just-ps150
https://food.lse.ac.uk/story/22370706/join-the-lse-food-club
https://food.lse.ac.uk/story/23026328/afternoon-deals-on-campus
https://food.lse.ac.uk/story/30432617/opening-hours
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://info.lse.ac.uk/staff/services/catering/order-catering
https://food.lse.ac.uk/story/13702322/5-benefits-of-using-a-keepcup','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=Columbia%20House%2C%20Aldwych%20London&travelmode=walking','2026-11-24'),
('C07','Independent','Nine Bars','4 Gate St, London WC2A 3HP','Lester','Assigned',null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null),
('C08','On-campus','Plaza Café','John Watkins Plaza, LSE',null,'Unassigned',null,null,null,null,null,null,'£2 Americano/espresso/tea + croissant/fruit before 09:30 (not latte/flat white); Food Club: 10th hot drink free, 5% points value; 25p paper cup charge.',2,'100–200','Counter / cashier ordering; Food Club app scanned at till (LSE scheme).','Matcha, sandwiches, sushi; plaza-side café',null,'Campus convenience / library','Mon–Thu 11:00–17:00 (published; conflicts with breakfast promotion)','£3.40 regular hot drink catering voucher, excl. VAT; not a retail flat white/latte quote.','Actual drink prices not published; optional quick menu-board photo. Published breakfast deal conflicts with Plaza''s listed opening time; confirm locally.','https://food.lse.ac.uk/story/40924571/a-guide-to-our-food-and-drink-outlets
https://food.lse.ac.uk/story/16625493/early-bird-breakfast-deal-just-ps150
https://food.lse.ac.uk/story/22370706/join-the-lse-food-club
https://food.lse.ac.uk/story/30432617/opening-hours
https://www.lse.ac.uk/lse-information/campus-map?from_serp=1
https://info.lse.ac.uk/staff/services/catering/order-catering
https://food.lse.ac.uk/story/13702322/5-benefits-of-using-a-keepcup','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=John%20Watkins%20Plaza%2C%20outside%20LSE%20Library%20London&travelmode=walking','2026-11-24'),
('C09','National chain','Pret - Kingsway','29-33 Kingsway, London WC2B 6UF','Kerem','Assigned',null,3.6,3.6,null,null,'Flat white 8 oz (UK published product); latte size unverified.','Club Pret £5/month; 50% off up to 5 eligible drinks/day; 50p reusable cup discount (not combined with Club Pret); Pret Perks.',4,'250–350','Counter service; delivery/collection offered by chain (local collection availability may vary).','Seating, breakfast, sandwiches, coffee','Wheelchair access stated; visual ordering TBC','Chain / convenience','Mon–Tue 06:30–20:00; Wed–Thu 06:30–19:30; Fri 06:30–18:30; weekends 08:00–18:30','UK standard shop benchmark, 2 Sep 2026; both £3.60. Delivery proxy £4.20 each (other branch). Verify Kingsway.','Price reference from different Pret branch (120–125 Strand), not a Kingsway price. Desk research lists the branch at: 29–33 Kingsway, WC2B 6UF.','https://www.pret.co.uk/en-GB/shop-finder/l/london/29-33-kingsway/47
https://www.pret.co.uk/en-GB/pret-faqs
https://www.ubereats.com/store/pret-a-manger-strand/2429d999-2edb-497a-ad94-4fc6426185eb
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://www.pret.co.uk/en-GB/products/UK006647/flat-white?category=Coffee
https://www.pret.co.uk/en-GB/pret-perks-rewards
https://www.pret.co.uk/en-GB/legal
https://menuverse.uk/pret-a-manger-menu/','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=29%E2%80%9333%20Kingsway%2C%20WC2B%206UF%20London&travelmode=walking','2026-11-24'),
('C10','National chain','Pret - Strand','190 Strand, Temple, London WC2R 1DP','Kerem','Assigned',null,3.6,3.6,null,null,'Flat white 8 oz (UK published product); latte size unverified.','Club Pret £5/month; 50% off up to 5 eligible drinks/day; 50p reusable cup discount (not combined with Club Pret); Pret Perks.',5,'300–450','Counter service; delivery/collection offered by chain (local collection availability may vary).','Coffee and food to go; seating TBC',null,'Chain / convenience',null,'UK standard shop benchmark, 2 Sep 2026; both £3.60. Delivery proxy £4.20 each (other branch). Verify Strand.','Target 190 Strand; £4.20 prices from 120–125 Strand delivery menu. Confirm target branch trading status.','https://staging-analytics.pret.ch/en-GB/shop-finder/l/london/190-strand/10786
https://www.pret.co.uk/en-GB/pret-faqs
https://www.ubereats.com/store/pret-a-manger-strand/2429d999-2edb-497a-ad94-4fc6426185eb
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://www.pret.co.uk/en-GB/products/UK006647/flat-white?category=Coffee
https://www.pret.co.uk/en-GB/pret-perks-rewards
https://www.pret.co.uk/en-GB/legal
https://menuverse.uk/pret-a-manger-menu/','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=190%20Strand%2C%20WC2R%201DP%20London&travelmode=walking','2026-11-24'),
('C11','Specialty / social purpose','Redemption Roasters','71 Lincoln''s Inn Fields, London WC2A 3JA','Lester','Assigned',null,null,null,null,null,null,null,5,'300–450',null,'Specialty coffee, pastries, cakes, focaccia; basement study seating; outdoor seating for 20.','Wheelchair access stated; visual ordering TBC','Specialty / social enterprise','Mon–Fri 07:30–17:30; Sat–Sun 09:00–17:00','No reliable in-store price; previous other-branch menu £4.00 each (not confirmed retail); Holborn review £3.60 flat white (historical).','Prison-leaver training and employment; Holborn actual drink prices not confirmed.','https://redemptionroasters.com/pages/locations_sub_page/holborn
https://redemptionroasters.com/
https://www.lse.ac.uk/lse-information/campus-map?from_serp=1
https://businessesmap.com/gb/london/coffee-shops/redemption-roasters-broadgate/menu
https://www.tripadvisor.co.uk/Restaurant_Review-g186338-d25364680-Reviews-Redemption_Roasters_Holborn-London_England.html','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=71%20Lincoln%27s%20Inn%20Fields%2C%20WC2A%203JA%20London&travelmode=walking','2026-11-24'),
('C12','Independent','Roasting Plant','190 Strand, Temple, London WC2R 3LL',null,'Unassigned',null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null),
('C13','Independent','SOHO The Strand','215 Strand, Temple, London WC2R 1AP',null,'Unassigned',null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null),
('C14','National chain','Starbucks','St. Katharine''s House, 10 Kingsway, London WC2B 6LH',null,'Unassigned',null,4.15,3.85,null,null,null,'Starbucks Rewards; terms apply',3,'150–250','Delivery / pickup listed on Uber Eats; local counter process not checked.','Coffee, iced drinks, sandwiches and bakery',null,'Chain / convenience','Mon–Fri 06:30–19:30; Sat–Sun 07:30–18:00 (delivery listing)','UK company-store benchmark, Sep 2026: flat white £4.15, latte tall £3.85 / grande £4.35. Kingsway delivery £5.20 each. Central London takeaway flat white reported £5.20 in July 2026. Verify branch.','Branch-specific delivery listing; not an in-store quote.','https://www.ubereats.com/store/starbucks-kingsway/jJCJLk5QUcuh6ci-cvX9-Q
https://www.starbucks.co.uk/article/851/changes-to-starbucksr-rewards
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://www.ubereats.com/gb/store/starbucks-kingsway/jJCJLk5QUcuh6ci-cvX9-Q
https://menuverse.uk/starbucks-menu/
https://www.theguardian.com/food/2026/jul/13/coffee-industry-inflationary-pressures-wage-tax-rises-uk','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=10%20Kingsway%2C%20Unit%20B2%2C%20WC2B%206LH%20London&travelmode=walking','2026-11-24'),
('C15','On-campus','The Bean Counter','Sir Arthur Lewis Building, LSE',null,'Unassigned',null,null,null,null,null,null,'£2 Americano/espresso/tea + croissant/fruit before 09:30 (not latte/flat white); Food Club: 10th hot drink free, 5% points value; 25p paper cup charge. £4.50 meal deal.',4,'200–350','Counter / cashier ordering; Food Club app scanned at till (LSE scheme).','Lower-ground café; organic coffee, pastries, study seating',null,'Campus convenience / study','Mon–Fri 08:30–16:00','£3.40 regular hot drink catering voucher, excl. VAT; not a retail flat white/latte quote.','Actual drink prices not published; optional quick menu-board photo.','https://food.lse.ac.uk/story/40924571/a-guide-to-our-food-and-drink-outlets
https://food.lse.ac.uk/story/16625493/early-bird-breakfast-deal-just-ps150
https://food.lse.ac.uk/story/22370706/join-the-lse-food-club
https://food.lse.ac.uk/story/30432617/opening-hours
https://food.lse.ac.uk/story/31209399/make-the-most-of-our-food-offers
https://www.lse.ac.uk/lse-information/campus-map?from_serp=1
https://info.lse.ac.uk/staff/services/catering/order-catering
https://food.lse.ac.uk/story/13702322/5-benefits-of-using-a-keepcup','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=Sir%20Arthur%20Lewis%20Building%2C%20lower%20ground%2C%2032%20Lincoln%27s%20Inn%20Fields%20London&travelmode=walking','2026-11-24'),
('C16','Independent','Wright''s Bar','Near LSE Old Building — verify exact entrance',null,'Unassigned',null,null,null,null,null,null,null,1,'50–100',null,'British/Italian-style café; breakfast, sandwiches, hot drinks.',null,'Independent value','Mon–Fri 07:00–18:00; Sat 07:00–13:00 (LSE facilities guide)','Historical generic coffee only; not comparable','Older undated LSE article cites 50p generic coffee; not a current or comparable flat-white/latte price. Check payment methods. Desk research lists the branch at: 63–65 Houghton Street, by Old Building.','https://info.lse.ac.uk/current-students/Assets/Articles/The-best-coffee-deals-around-campus
https://streets.openalfa.co.uk/streets/houghton-street-wc2b-st-clement-danes
https://info.lse.ac.uk/current-students/estates-Division/Facilities-Guide/Food-and-Drink','https://www.google.com/maps/dir/?api=1&origin=LSE%20Centre%20Building%20Houghton%20Street%20London&destination=63%E2%80%9365%20Houghton%20Street%2C%20by%20Old%20Building%20London&travelmode=walking','2026-11-24')
on conflict (id) do nothing;

-- queue observations Q01–Q15 (only added once)
insert into public.queue_obs (code, competitor_id, observer, obs_date, obs_time, people, tills, notes)
select v.code, v.cid, v.obs, v.d::date, v.t::time, v.p, v.tl, v.n from (values
('Q01','C11','Lester','2026-11-24','13:25',5,null,null),
('Q02','C02','Lester','2026-11-24','13:15',3,1,null),
('Q03','C07','Lester','2026-11-24','13:25',1,null,null),
('Q04','C11','Lester','2026-11-25','10:55',2,null,null),
('Q05','C07','Lester','2026-11-25','10:55',0,null,null),
('Q06','C11','Lester','2026-11-25','16:00',0,null,null),
('Q07','C07','Lester','2026-11-25','16:00',3,null,null),
('Q08','C04','Kerem','2026-11-26',null,1,null,null),
('Q09','C09','Kerem','2026-11-26',null,0,null,null),
('Q10','C10','Kerem','2026-11-26',null,null,null,null),
('Q11','C01','Lili','2026-11-26','11:00',14,1,null),
('Q12','C11','Lester','2026-11-26','13:30',1,null,null),
('Q13','C07','Lester','2026-11-26','13:30',0,null,null),
('Q14','C14','Lester','2026-11-26','13:40',1,null,null),
('Q15','C14','Lester','2026-11-26','19:00',0,null,null)
) as v(code, cid, obs, d, t, p, tl, n)
where not exists (select 1 from public.queue_obs q where q.code = v.code);

do $$ begin alter publication supabase_realtime add table public.competitors; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.queue_obs; exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';

-- update 6: experiments

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
