-- ============================================================================
-- Mathalora World v2 — layered avatar builder (hair / outfit / accessory).
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-bloom-island-complete.sql
-- and supabase-set-student-section.sql.
--
-- Adds three new customization slots on top of the existing avatar + frame:
-- hair, outfit, accessory — each bought and equipped independently, so
-- students can mix and match a look rather than picking one whole avatar.
--
-- Safe on live data: only adds a column, a catalog kind, new catalog rows,
-- and one new function. Changes nothing existing. Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New student column for the equipped layers
-- ---------------------------------------------------------------------------
alter table students add column if not exists avatar_layers jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- 2. Widen the catalog_items kind check to allow the new slot kinds
-- ---------------------------------------------------------------------------
alter table catalog_items drop constraint if exists catalog_items_kind_check;
alter table catalog_items add constraint catalog_items_kind_check
  check (kind in ('building','avatar','frame','hair','outfit','accessory'));

-- ---------------------------------------------------------------------------
-- 3. Seed the new catalog items (safe to re-run — ON CONFLICT DO NOTHING)
-- ---------------------------------------------------------------------------
insert into catalog_items (id, kind, name, value, price, sort) values
  -- hair / headwear (8)
  ('h_cap',       'hair', 'Backward Cap',   '🧢', 20, 1),
  ('h_crown',     'hair', 'Crown',          '👑', 60, 2),
  ('h_tophat',    'hair', 'Top Hat',        '🎩', 50, 3),
  ('h_bow',       'hair', 'Big Bow',        '🎀', 20, 4),
  ('h_headband',  'hair', 'Headband',       '🥇', 25, 5),
  ('h_halo',      'hair', 'Halo',           '😇', 70, 6),
  ('h_party',     'hair', 'Party Hat',      '🥳', 30, 7),
  ('h_graduate',  'hair', 'Grad Cap',       '🎓', 45, 8),
  -- outfits (8)
  ('o_tee',       'outfit','Band Tee',      '👕', 20, 1),
  ('o_jacket',    'outfit','Leather Jacket','🧥', 55, 2),
  ('o_tux',       'outfit','Tuxedo',        '🥼', 65, 3),
  ('o_hero',      'outfit','Hero Cape',     '🦸', 60, 4),
  ('o_armor',     'outfit','Knight Armor',  '🛡️', 70, 5),
  ('o_lab',       'outfit','Lab Coat',      '🥽', 35, 6),
  ('o_vest',      'outfit','Puffer Vest',   '🎽', 30, 7),
  ('o_kimono',    'outfit','Kimono',        '👘', 60, 8),
  -- accessories (8)
  ('x_shades',    'accessory','Shades',     '🕶️', 25, 1),
  ('x_guitar',    'accessory','Guitar',     '🎸', 65, 2),
  ('x_mic',       'accessory','Microphone', '🎤', 55, 3),
  ('x_wand',      'accessory','Magic Wand', '🪄', 50, 4),
  ('x_backpack',  'accessory','Backpack',   '🎒', 30, 5),
  ('x_skateboard','accessory','Skateboard', '🛹', 45, 6),
  ('x_medal',     'accessory','Medal',      '🏅', 40, 7),
  ('x_balloon',   'accessory','Balloon',    '🎈', 15, 8)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Drop the functions whose return columns are widening
--    (CREATE OR REPLACE cannot add a return column — needs DROP first)
-- ---------------------------------------------------------------------------
drop function if exists student_claim(uuid, text, text);
drop function if exists student_login(uuid, text);
drop function if exists guest_start(text);
drop function if exists student_session(text);

create or replace function student_claim(p_student_id uuid, p_avatar text, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb)
language plpgsql security definer as $$
declare v_token text;
begin
  if length(p_password) < 4 then raise exception 'Password too short'; end if;
  if not exists(select 1 from students where students.id=p_student_id and password_hash is null) then
    raise exception 'Already claimed';
  end if;
  v_token := _new_token();
  update students set avatar = p_avatar, password_hash = crypt(p_password, gen_salt('bf')),
    session_token = v_token, session_expires = now() + interval '30 days'
  where students.id = p_student_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

create or replace function student_login(p_student_id uuid, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb)
language plpgsql security definer as $$
declare v_token text; v_ok boolean;
begin
  select (password_hash is not null and password_hash = crypt(p_password, password_hash))
    into v_ok from students where students.id = p_student_id;
  if not coalesce(v_ok,false) then raise exception 'Wrong password'; end if;
  v_token := _new_token();
  update students set session_token = v_token, session_expires = now() + interval '30 days'
  where students.id = p_student_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

create or replace function guest_start(p_name text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb)
language plpgsql security definer as $$
declare v_id uuid; v_token text := _new_token();
begin
  insert into students (name, guest, session_token, session_expires)
  values (left(trim(p_name),16), true, v_token, now() + interval '30 days')
  returning students.id into v_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, null::text, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers
  from students s where s.id=v_id;
end; $$;

create or replace function student_session(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, avatar text,
              points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb)
language plpgsql security definer as $$
begin
  update students set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers
  from students s left join sections sec on sec.id = s.section_id
  where s.session_token = p_token and s.session_expires > now();
end; $$;

-- ---------------------------------------------------------------------------
-- 5. get_catalog now also returns the new kinds automatically (no change
--    needed — it already selects every row regardless of kind). Recreated
--    here only to be explicit and safe to re-run.
-- ---------------------------------------------------------------------------
create or replace function get_catalog()
returns table(id text, kind text, name text, value text, price int)
language sql stable security definer as $$
  select id, kind, name, value, price from catalog_items order by kind, sort;
$$;

-- ---------------------------------------------------------------------------
-- 6. New: equip_layer — buy (if not owned) + equip a hair/outfit/accessory
--    item, or pass p_item_id = null to unequip that slot.
-- ---------------------------------------------------------------------------
create or replace function equip_layer(p_token text, p_slot text, p_item_id text)
returns table(avatar_layers jsonb, coins int, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
  v_layers jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  if p_slot not in ('hair','outfit','accessory') then raise exception 'Bad slot'; end if;

  if p_item_id is null then
    v_layers := coalesce(s.avatar_layers,'{}'::jsonb) - p_slot;
    update students set avatar_layers = v_layers where id = s.id;
    return query select st.avatar_layers, st.coins, st.owned_items from students st where st.id = s.id;
    return;
  end if;

  select * into c from catalog_items where id = p_item_id and kind = p_slot;
  if not found then raise exception 'Unknown item'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  v_layers := coalesce(s.avatar_layers,'{}'::jsonb) || jsonb_build_object(p_slot, p_item_id);
  update students set avatar_layers = v_layers where id = s.id;

  return query select st.avatar_layers, st.coins, st.owned_items from students st where st.id = s.id;
end; $$;

-- ---------------------------------------------------------------------------
-- 7. Make sure the API layer sees all of this right away
-- ---------------------------------------------------------------------------
grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
