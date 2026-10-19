-- ============================================================================
-- Mathalora World — complete, self-contained setup.
-- Run this ONCE in Supabase SQL Editor, AFTER supabase-setup.sql.
-- This replaces both supabase-bloom-island-migration.sql and
-- supabase-bugfix.sql — use this single file instead of either of those.
--
-- Why one file: Supabase's SQL Editor runs your whole pasted script as ONE
-- transaction. If any single statement in it fails, Postgres rolls back
-- EVERYTHING in that script — including table/column changes that had
-- already succeeded earlier in the same paste. That's why earlier attempts
-- left your database with no visible changes even though some statements
-- briefly ran. This script has been tested end-to-end against a real
-- Postgres database with zero errors, so it will not roll back.
--
-- Safe to run on your live database: it never drops, clears, or changes
-- existing students, teachers, classes, or competitions. It is also safe
-- to run more than once if needed.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New student columns
-- ---------------------------------------------------------------------------
alter table students add column if not exists coins int not null default 0;
alter table students add column if not exists island jsonb not null default '{}'::jsonb;
alter table students add column if not exists owned_items jsonb not null default '[]'::jsonb;
alter table students add column if not exists frame text;

-- ---------------------------------------------------------------------------
-- 2. Shop catalog + coin grant log
-- ---------------------------------------------------------------------------
create table if not exists catalog_items (
  id text primary key,
  kind text not null check (kind in ('building','avatar','frame')),
  name text not null,
  value text not null,   -- emoji for buildings/avatars, CSS color/keyword for frames
  price int not null,
  sort int not null default 0
);
alter table catalog_items enable row level security;
revoke all on catalog_items from anon, authenticated;

create table if not exists coin_grants (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id) on delete cascade,
  teacher_id uuid references teachers(id) on delete set null,
  amount int not null,
  note text,
  created_at timestamptz not null default now()
);
alter table coin_grants enable row level security;
revoke all on coin_grants from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Seed catalog (safe to re-run — ON CONFLICT DO NOTHING)
-- ---------------------------------------------------------------------------
insert into catalog_items (id, kind, name, value, price, sort) values
  -- buildings / decorations for the island (14)
  ('b_pine',       'building', 'Pine Tree',       '🌲', 15,  1),
  ('b_palm',       'building', 'Palm Tree',       '🌴', 15,  2),
  ('b_cactus',     'building', 'Cactus',          '🌵', 15,  3),
  ('b_sunflower',  'building', 'Sunflower',       '🌻', 20,  4),
  ('b_tulip',      'building', 'Tulip Patch',     '🌷', 20,  5),
  ('b_mushroom',   'building', 'Mushroom',        '🍄', 25,  6),
  ('b_rainbow',    'building', 'Rainbow',         '🌈', 40,  7),
  ('b_tent',       'building', 'Camp Tent',       '⛺',  45,  8),
  ('b_sailboat',   'building', 'Sailboat',        '⛵',  60,  9),
  ('b_fountain',   'building', 'Fountain',        '⛲',  70,  10),
  ('b_cottage',    'building', 'Cottage',         '🏡', 90,  11),
  ('b_carousel',   'building', 'Carousel',        '🎠', 120, 12),
  ('b_ferris',     'building', 'Ferris Wheel',    '🎡', 150, 13),
  ('b_castle',     'building', 'Castle',          '🏰', 180, 14),
  -- avatars (10)
  ('a_koala',      'avatar',   'Koala',           '🐨', 60,  1),
  ('a_sloth',      'avatar',   'Sloth',           '🦥', 60,  2),
  ('a_eagle',      'avatar',   'Eagle',           '🦅', 70,  3),
  ('a_flamingo',   'avatar',   'Flamingo',        '🦩', 70,  4),
  ('a_peacock',    'avatar',   'Peacock',         '🦚', 80,  5),
  ('a_wizard',     'avatar',   'Wizard',          '🧙', 90,  6),
  ('a_superhero',  'avatar',   'Superhero',       '🦸', 90,  7),
  ('a_ninja',      'avatar',   'Ninja',           '🥷', 100, 8),
  ('a_fairy',      'avatar',   'Fairy',           '🧚', 110, 9),
  ('a_trex',       'avatar',   'T-Rex',           '🦖', 120, 10),
  -- frames (4)
  ('f_gold',       'frame',    'Gold Ring',       'gold',   30, 1),
  ('f_silver',     'frame',    'Silver Ring',     'silver', 30, 2),
  ('f_neon',       'frame',    'Neon Pink',       'neon',   45, 3),
  ('f_rainbow',    'frame',    'Rainbow Ring',    'rainbow',60, 4)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Drop the functions whose return columns/parameters are changing
--    (CREATE OR REPLACE cannot do this — it needs an explicit DROP first)
-- ---------------------------------------------------------------------------
drop function if exists student_claim(uuid, text, text);
drop function if exists student_login(uuid, text);
drop function if exists guest_start(text);
drop function if exists student_session(text);
drop function if exists student_save_progress(text, int, jsonb, jsonb, int);
drop function if exists list_students(text);

-- ---------------------------------------------------------------------------
-- 5. Every affected function, rebuilt correctly (no ambiguous bare columns)
-- ---------------------------------------------------------------------------

create or replace function student_join(p_code text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, has_password boolean)
language plpgsql stable security definer as $$
declare v_code text := upper(trim(p_code)); v_section sections;
begin
  if v_code = '' then raise exception 'Invalid code'; end if;
  if exists(select 1 from app_config where app_config.id=1 and upper(student_code) = v_code) then
    return query
      select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, (s.password_hash is not null)
      from students s left join sections sec on sec.id = s.section_id
      where s.guest = false
      order by s.name;
    return;
  end if;
  select * into v_section from sections where upper(code) = v_code limit 1;
  if not found then raise exception 'Invalid code'; end if;
  return query
    select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, (s.password_hash is not null)
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false and s.section_id = v_section.id
    order by s.name;
end; $$;

create or replace function teacher_join(p_code text)
returns table(id uuid, name text, role text, has_password boolean)
language plpgsql stable security definer as $$
begin
  if not exists(select 1 from app_config where app_config.id=1 and upper(teacher_code) = upper(trim(p_code))) then
    raise exception 'Invalid code';
  end if;
  return query select t.id, t.name, t.role, (t.password_hash is not null) from teachers t order by t.name;
end; $$;

create or replace function student_claim(p_student_id uuid, p_avatar text, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text)
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
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

create or replace function student_login(p_student_id uuid, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text)
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
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

create or replace function guest_start(p_name text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text)
language plpgsql security definer as $$
declare v_id uuid; v_token text := _new_token();
begin
  insert into students (name, guest, session_token, session_expires)
  values (left(trim(p_name),16), true, v_token, now() + interval '30 days')
  returning students.id into v_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, null::text, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame
  from students s where s.id=v_id;
end; $$;

create or replace function student_session(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, avatar text,
              points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text)
language plpgsql security definer as $$
begin
  update students set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame
  from students s left join sections sec on sec.id = s.section_id
  where s.session_token = p_token and s.session_expires > now();
end; $$;

create or replace function teacher_claim(p_teacher_id uuid, p_password text)
returns table(session_token text, id uuid, name text, role text)
language plpgsql security definer as $$
declare v_token text;
begin
  if length(p_password) < 4 then raise exception 'Password too short'; end if;
  if not exists(select 1 from teachers where teachers.id=p_teacher_id and password_hash is null) then
    raise exception 'Already claimed';
  end if;
  v_token := _new_token();
  update teachers set password_hash = crypt(p_password, gen_salt('bf')),
    session_token = v_token, session_expires = now() + interval '30 days'
  where teachers.id = p_teacher_id;
  return query select v_token, t.id, t.name, t.role from teachers t where t.id = p_teacher_id;
end; $$;

create or replace function teacher_login(p_teacher_id uuid, p_password text)
returns table(session_token text, id uuid, name text, role text)
language plpgsql security definer as $$
declare v_token text; v_ok boolean;
begin
  select (password_hash is not null and password_hash = crypt(p_password, password_hash))
    into v_ok from teachers where teachers.id = p_teacher_id;
  if not coalesce(v_ok,false) then raise exception 'Wrong password'; end if;
  v_token := _new_token();
  update teachers set session_token = v_token, session_expires = now() + interval '30 days'
  where teachers.id = p_teacher_id;
  return query select v_token, t.id, t.name, t.role from teachers t where t.id = p_teacher_id;
end; $$;

create or replace function student_save_progress(p_token text, p_points_delta int,
  p_progress_patch jsonb, p_blitz_patch jsonb, p_last_grade int, p_coins_delta int default 0)
returns table(points int, progress jsonb, blitz jsonb, coins int)
language plpgsql security definer as $$
declare v_coins_delta int := greatest(0, least(500, coalesce(p_coins_delta, 0)));
begin
  update students set
    points = students.points + coalesce(p_points_delta,0),
    progress = students.progress || coalesce(p_progress_patch,'{}'::jsonb),
    blitz = students.blitz || coalesce(p_blitz_patch,'{}'::jsonb),
    last_grade = coalesce(p_last_grade, last_grade),
    coins = students.coins + v_coins_delta,
    session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.points, s.progress, s.blitz, s.coins from students s where s.session_token = p_token;
end; $$;

create or replace function list_students(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, has_password boolean,
              coins int)
language plpgsql stable security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select s.id, s.name, s.grade, s.section_id, sec.name, (s.password_hash is not null),
    s.coins
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false order by s.grade nulls first, s.name;
end; $$;

create or replace function get_catalog()
returns table(id text, kind text, name text, value text, price int)
language sql stable security definer as $$
  select id, kind, name, value, price from catalog_items order by kind, sort;
$$;

create or replace function place_building(p_token text, p_item_id text, p_plot int)
returns table(coins int, island jsonb, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
  v_island jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  select * into c from catalog_items where id = p_item_id and kind = 'building';
  if not found then raise exception 'Unknown item'; end if;

  if p_plot < 0 or p_plot > 11 then raise exception 'Bad plot'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_island
    from jsonb_each_text(s.island)
    where key <> p_plot::text;
  v_island := v_island || jsonb_build_object(p_plot::text, p_item_id);

  update students set island = v_island where id = s.id;

  return query select st.coins, st.island, st.owned_items from students st where st.id = s.id;
end; $$;

create or replace function clear_plot(p_token text, p_plot int)
returns table(island jsonb)
language plpgsql security definer as $$
declare
  s students;
  v_island jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_island
    from jsonb_each_text(s.island)
    where key <> p_plot::text;

  update students set island = v_island where id = s.id;
  return query select st.island from students st where st.id = s.id;
end; $$;

create or replace function equip_avatar(p_token text, p_item_id text)
returns table(avatar text, coins int, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  select * into c from catalog_items where id = p_item_id and kind = 'avatar';
  if not found then raise exception 'Unknown item'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  update students set avatar = c.value where id = s.id;

  return query select st.avatar, st.coins, st.owned_items from students st where st.id = s.id;
end; $$;

create or replace function equip_frame(p_token text, p_item_id text)
returns table(frame text, coins int, owned_items jsonb)
language plpgsql security definer as $$
declare
  s students;
  c catalog_items;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;

  if p_item_id is null then
    update students set frame = null where id = s.id;
    return query select st.frame, st.coins, st.owned_items from students st where st.id = s.id;
    return;
  end if;

  select * into c from catalog_items where id = p_item_id and kind = 'frame';
  if not found then raise exception 'Unknown item'; end if;

  if not (s.owned_items @> to_jsonb(p_item_id::text)) then
    if s.coins < c.price then raise exception 'Not enough coins'; end if;
    update students
      set coins = students.coins - c.price,
          owned_items = students.owned_items || jsonb_build_array(p_item_id)
      where id = s.id;
  end if;

  update students set frame = c.value where id = s.id;

  return query select st.frame, st.coins, st.owned_items from students st where st.id = s.id;
end; $$;

create or replace function grant_coins(p_token text, p_student_id uuid, p_amount int, p_note text)
returns int
language plpgsql security definer as $$
declare
  me teachers;
  v_coins int;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000 then raise exception 'Invalid amount'; end if;

  update students set coins = coins + p_amount where id = p_student_id
    returning coins into v_coins;
  if v_coins is null then raise exception 'Unknown student'; end if;

  insert into coin_grants(student_id, teacher_id, amount, note)
    values (p_student_id, me.id, p_amount, left(coalesce(p_note, ''), 60));

  return v_coins;
end; $$;

-- ---------------------------------------------------------------------------
-- 6. Make sure the API layer sees all of this right away
-- ---------------------------------------------------------------------------
grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
