-- ============================================================================
-- Mathalora World — free-form building (Farmville-style placement).
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-bloom-island-v2.sql.
--
-- Until now, decorations lived in a fixed 12-slot grid:
--   island = {"0": "b_pine", "3": "b_cottage", ...}     (slot index -> item id)
-- This migration rewrites every student's island data to a free-placement
-- format and adds new functions to place/move/remove items anywhere on the
-- map instead of in a fixed grid:
--   island = {"<random-key>": {"id":"b_pine","x":22,"y":68}, ...}
--
-- Anything already placed in the old grid is kept — it's converted onto the
-- same 4-column x 3-row layout it used to occupy, so nothing disappears.
-- Safe to run on live data, and safe to re-run (already-migrated rows are
-- left untouched on a second run).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. One-time rewrite of existing island data to the new format
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  old_entry record;
  new_island jsonb;
  slot int;
  gx int; gy int;
begin
  for r in select id, island from students where island is not null and island <> '{}'::jsonb loop
    new_island := '{}'::jsonb;
    for old_entry in select key, value from jsonb_each(r.island) loop
      if jsonb_typeof(old_entry.value) = 'string' then
        slot := old_entry.key::int;
        gx := 12 + (slot % 4) * 25;
        gy := 20 + (slot / 4) * 30;
        new_island := new_island || jsonb_build_object(
          gen_random_uuid()::text,
          jsonb_build_object('id', trim(both '"' from old_entry.value::text), 'x', gx, 'y', gy)
        );
      else
        new_island := new_island || jsonb_build_object(old_entry.key, old_entry.value);
      end if;
    end loop;
    update students set island = new_island where id = r.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. New placement functions (the old place_building/clear_plot are left in
--    place, unused, so nothing breaks if an old page is still open mid-deploy)
-- ---------------------------------------------------------------------------
create or replace function place_building_at(p_token text, p_item_id text, p_key text, p_x numeric, p_y numeric)
returns table(coins int, island jsonb, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
  v_key text := coalesce(p_key, gen_random_uuid()::text);
  v_x numeric := greatest(2, least(98, coalesce(p_x,50)));
  v_y numeric := greatest(6, least(94, coalesce(p_y,50)));
  v_count int;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  select * into c from catalog_items where id = p_item_id and kind = 'building';
  if not found then raise exception 'Unknown item'; end if;

  select count(*) into v_count from jsonb_object_keys(coalesce(s.island,'{}'::jsonb));
  if not (coalesce(s.island,'{}'::jsonb) ? v_key) and v_count >= 40 then
    raise exception 'Island is full';
  end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  update students
    set island = coalesce(s.island,'{}'::jsonb) || jsonb_build_object(v_key, jsonb_build_object('id',p_item_id,'x',v_x,'y',v_y))
    where id = s.id;

  return query select st.coins, st.island, st.owned_items from students st where st.id = s.id;
end; $$;

create or replace function move_building(p_token text, p_key text, p_x numeric, p_y numeric)
returns table(island jsonb)
language plpgsql security definer as $$
declare
  s students;
  v_x numeric := greatest(2, least(98, coalesce(p_x,50)));
  v_y numeric := greatest(6, least(94, coalesce(p_y,50)));
  v_item jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  if not (coalesce(s.island,'{}'::jsonb) ? p_key) then raise exception 'Unknown placement'; end if;
  v_item := s.island->p_key;
  update students
    set island = s.island || jsonb_build_object(p_key, jsonb_build_object('id', v_item->>'id', 'x', v_x, 'y', v_y))
    where id = s.id;
  return query select st.island from students st where st.id = s.id;
end; $$;

create or replace function clear_building(p_token text, p_key text)
returns table(island jsonb)
language plpgsql security definer as $$
declare
  s students;
  v_island jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_island
    from jsonb_each(coalesce(s.island,'{}'::jsonb))
    where key <> p_key;
  update students set island = v_island where id = s.id;
  return query select st.island from students st where st.id = s.id;
end; $$;

-- ---------------------------------------------------------------------------
-- 3. Make sure the API layer sees all of this right away
-- ---------------------------------------------------------------------------
grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
