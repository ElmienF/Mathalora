-- ============================================================================
-- Mathalora — vehicles for the new path-map level view.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-school-admin.sql.
--
-- Levels (on a grade screen) and each curriculum island's five steps are
-- about to be shown as stops along a themed path — a road for a car, a
-- route for a ship, a flight path for an aeroplane, a trail for a bicycle
-- — with the student's own avatar riding along it. This adds the data
-- side of that: a new purchasable "vehicle" (the base ride) and
-- "vehicle_accessory" (one decoration on top of it, same pattern as the
-- existing avatar "frame") catalog kind, mirroring exactly how avatars,
-- frames and the hair/outfit/accessory layers already work —
-- buy-if-not-owned-then-equip, paid for with the same coins, using the
-- same owned_items ownership list.
--
--   - students.vehicle            — the equipped vehicle's TYPE KEYWORD
--     ('bicycle','car','ship','plane'), not an emoji, so the client can
--     theme the whole path (road / sea route / flight path / trail) from
--     one value. Null until a student equips one for the first time.
--   - students.vehicle_accessory  — one equipped decoration's emoji
--     (racing stripes, a flag, lights, a basket, a trailer), same
--     single-slot pattern as the existing avatar frame. Null = none.
--
--   - equip_vehicle(p_token, p_item_id)            — buy (if not already
--     owned) and equip a vehicle. p_item_id null is not meaningful here
--     (there's always a default "no vehicle yet" state before the first
--     equip, same as a brand new avatar before signup) so this one does
--     not accept null, unlike equip_frame.
--   - equip_vehicle_accessory(p_token, p_item_id)  — buy (if not already
--     owned) and equip an accessory; p_item_id null removes it, exactly
--     like equip_frame.
--
-- Bicycle is seeded free (price 0) so every student has a themed path
-- the moment they first equip anything, same as the free starter
-- hair/outfit from supabase-avatar-basics.sql. Car, ship and aeroplane
-- are paid upgrades.
--
-- Safe on live data: only adds two columns, widens the catalog kind
-- check, adds catalog rows, and adds two new functions. Changes nothing
-- existing. Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New student columns
-- ---------------------------------------------------------------------------
alter table students add column if not exists vehicle text;
alter table students add column if not exists vehicle_accessory text;

-- ---------------------------------------------------------------------------
-- 2. Widen the catalog_items kind check
-- ---------------------------------------------------------------------------
alter table catalog_items drop constraint if exists catalog_items_kind_check;
alter table catalog_items add constraint catalog_items_kind_check
  check (kind in ('building','avatar','frame','hair','outfit','accessory','vehicle','vehicle_accessory'));

-- ---------------------------------------------------------------------------
-- 3. Seed the vehicles + vehicle accessories (safe to re-run)
-- ---------------------------------------------------------------------------
insert into catalog_items (id, kind, name, value, price, sort) values
  -- vehicles: bicycle free (starter), rest paid upgrades
  ('v_bicycle', 'vehicle', 'Bicycle',    'bicycle', 0,   1),
  ('v_car',     'vehicle', 'Car',        'car',     80,  2),
  ('v_ship',    'vehicle', 'Ship',       'ship',    120, 3),
  ('v_plane',   'vehicle', 'Aeroplane',  'plane',   150, 4),
  -- vehicle accessories: one decoration equipped on top of the vehicle
  ('va_basket',   'vehicle_accessory', 'Basket',         '🧺', 15, 1),
  ('va_stripes',  'vehicle_accessory', 'Racing Stripes', '🏁', 25, 2),
  ('va_flag',     'vehicle_accessory', 'Flag',           '🚩', 20, 3),
  ('va_lights',   'vehicle_accessory', 'Light Trail',    '✨', 30, 4),
  ('va_trailer',  'vehicle_accessory', 'Trailer',        '📦', 35, 5)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Widen student_session to also return the new columns
--    (CREATE OR REPLACE cannot add a return column — needs DROP first).
--    list_students (the teacher roster) doesn't need these — left as is.
-- ---------------------------------------------------------------------------
drop function if exists student_session(text);

create or replace function student_session(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, avatar text,
              points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb,
              behavior_coins_total int, format_coins_total int, vehicle text, vehicle_accessory text)
language plpgsql security definer as $$
begin
  update students set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers,
    s.behavior_coins_total, s.format_coins_total, s.vehicle, s.vehicle_accessory
  from students s left join sections sec on sec.id = s.section_id
  where s.session_token = p_token and s.session_expires > now();
end; $$;

-- ---------------------------------------------------------------------------
-- 5. Equip (buy if not owned) a vehicle, or a vehicle accessory
-- ---------------------------------------------------------------------------
create or replace function equip_vehicle(p_token text, p_item_id text)
returns table(vehicle text, coins int, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  select * into c from catalog_items where id = p_item_id and kind = 'vehicle';
  if not found then raise exception 'Unknown item'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  update students set vehicle = c.value where id = s.id;

  return query select st.vehicle, st.coins, st.owned_items from students st where st.id = s.id;
end; $$;

create or replace function equip_vehicle_accessory(p_token text, p_item_id text)
returns table(vehicle_accessory text, coins int, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  if p_item_id is null then
    update students set vehicle_accessory = null where id = s.id;
    return query select st.vehicle_accessory, st.coins, st.owned_items from students st where st.id = s.id;
    return;
  end if;

  select * into c from catalog_items where id = p_item_id and kind = 'vehicle_accessory';
  if not found then raise exception 'Unknown item'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  update students set vehicle_accessory = c.value where id = s.id;

  return query select st.vehicle_accessory, st.coins, st.owned_items from students st where st.id = s.id;
end; $$;

-- ---------------------------------------------------------------------------
-- 6. Make sure the API layer sees all of this right away
-- ---------------------------------------------------------------------------
grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
