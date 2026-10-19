-- ============================================================================
-- Mathalora — multi-tenant platform, part 2: close the remaining cross-school
-- leaks. Run this ONCE in the Supabase SQL Editor, AFTER
-- supabase-multitenant-01.sql.
--
-- Part 1 scoped identity/roster (teachers, students, sections) to schools.
-- Everything else — competitions, coin grants, presence, duels, raids — was
-- still running unscoped, which on a SECOND school would mean:
--   - any teacher could grant coins to, or reassign the class of, a student
--     in a DIFFERENT school just by guessing/enumerating their id
--   - students saw EVERY other online student on the shared Explore map,
--     and could raid same-grade students, regardless of school
--   - a duel code from one school could be joined by a student at another
--   - the public gate's "upcoming competitions" and the leaderboard mixed
--     every school's data together
-- This migration closes all of those. It's additive/corrective only — no
-- data is deleted. Safe to re-run.
-- ============================================================================

-- ---------- duels need a school_id to tell two same-code-space duels apart ----------
alter table duels add column if not exists school_id uuid references schools(id) on delete cascade;
update duels set school_id = (select s.school_id from students s where s.id = duels.creator_id) where school_id is null;

-- ---------- competitions: teacher-facing CRUD, scoped to the caller's school ----------

create or replace function list_competitions(p_token text)
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
    from competitions c where c.school_id = me.school_id order by c.start_date;
end; $$;

create or replace function add_competition(p_token text, p_name text, p_scope_type text,
  p_scope_grade int, p_scope_section_id uuid, p_start date, p_end date)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if p_scope_section_id is not null and not exists(
      select 1 from sections where sections.id = p_scope_section_id and sections.school_id = me.school_id) then
    raise exception 'Unknown item';
  end if;
  insert into competitions(school_id, name,scope_type,scope_grade,scope_section_id,start_date,end_date)
  values (me.school_id, left(trim(p_name),40), p_scope_type, p_scope_grade, p_scope_section_id, p_start, p_end);
end; $$;

create or replace function delete_competition(p_token text, p_competition_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  delete from competitions where id = p_competition_id and school_id = me.school_id;
end; $$;

-- Logged-in student's own competitions (home screen). Derives the student
-- (and therefore school/grade/section) from their session instead of
-- trusting client-supplied grade/section values.
drop function if exists competitions_for(int, uuid);
create or replace function competitions_for(p_token text)
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
    from competitions c
    where c.school_id = s.school_id and c.end_date >= current_date and (
      c.scope_type = 'school'
      or (c.scope_type = 'grade' and c.scope_grade = s.grade)
      or (c.scope_type = 'section' and c.scope_section_id = s.section_id)
    )
    order by c.start_date;
end; $$;

-- Public gate screen, before anyone is signed in. Pre-dates the school
-- picker UI, so — same soft-landing pattern as public_config() — this shows
-- the first school's whole-school competitions only. Once a "pick your
-- school" step exists client-side, replace this with a p_school_id version.
create or replace function competitions_for_gate()
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language sql stable security definer as $$
  select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
  from competitions c
  where c.scope_type = 'school' and c.end_date >= current_date
    and c.school_id = (select id from schools order by created_at limit 1)
  order by c.start_date;
$$;

create or replace function competition_leaderboard(p_competition_id uuid, p_limit int default 5)
returns table(name text, points int)
language plpgsql stable security definer as $$
declare c competitions;
begin
  select * into c from competitions where id = p_competition_id;
  if not found then return; end if;
  return query
    select s.name, s.points from students s
    where s.guest = false and s.school_id = c.school_id and (
      c.scope_type = 'school'
      or (c.scope_type = 'grade' and s.grade = c.scope_grade)
      or (c.scope_type = 'section' and s.section_id = c.scope_section_id)
    )
    order by s.points desc limit p_limit;
end; $$;

-- ---------- sections: close two gaps left from part 1 ----------

create or replace function delete_section(p_token text, p_section_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  update students set section_id = null where section_id = p_section_id
    and section_id in (select id from sections where sections.school_id = me.school_id);
  delete from sections where id = p_section_id and school_id = me.school_id;
end; $$;

create or replace function new_section_code(p_token text, p_section_id uuid)
returns text language plpgsql security definer as $$
declare me teachers; v text;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if not exists(select 1 from sections where sections.id = p_section_id and sections.school_id = me.school_id) then
    raise exception 'Unknown item';
  end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update sections set code = v where id = p_section_id;
  return v;
end; $$;

create or replace function set_student_section(p_token text, p_student_id uuid, p_section_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  if not exists(select 1 from students where students.id = p_student_id and students.school_id = me.school_id) then
    raise exception 'Unknown item';
  end if;
  if p_section_id is not null and not exists(
      select 1 from sections where sections.id = p_section_id and sections.school_id = me.school_id) then
    raise exception 'Unknown item';
  end if;
  update students set section_id = p_section_id where id = p_student_id;
end; $$;

-- ---------- coins ----------

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

  update students set coins = coins + p_amount where id = p_student_id and school_id = me.school_id
    returning coins into v_coins;
  if v_coins is null then raise exception 'Unknown student'; end if;

  insert into coin_grants(student_id, teacher_id, amount, note)
    values (p_student_id, me.id, p_amount, left(coalesce(p_note, ''), 60));

  return v_coins;
end; $$;

-- ---------- presence: only ever show/raid/duel students at your own school ----------

create or replace function update_presence(p_token text, p_x numeric, p_y numeric)
returns table(id uuid, name text, avatar text, avatar_layers jsonb, frame text, x numeric, y numeric)
language plpgsql security definer as $$
declare s students; v_x numeric; v_y numeric;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  v_x := greatest(0, least(100, coalesce(p_x,50)));
  v_y := greatest(0, least(100, coalesce(p_y,50)));

  insert into presence (student_id, x, y, updated_at)
    values (s.id, v_x, v_y, now())
    on conflict (student_id) do update set x = v_x, y = v_y, updated_at = now();

  return query
    select st.id, st.name, st.avatar, st.avatar_layers, st.frame, p.x, p.y
    from presence p
    join students st on st.id = p.student_id
    where p.student_id <> s.id and p.updated_at > now() - interval '8 seconds'
      and st.school_id = s.school_id
    order by p.updated_at desc
    limit 60;
end; $$;

-- ---------- duels: a code from one school can no longer be joined at another ----------

create or replace function create_duel(p_token text, p_level int, p_target int default 10)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language plpgsql security definer as $$
declare s students; v_id uuid; v_code text; v_target int := greatest(3, least(20, coalesce(p_target,10)));
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  if p_level is null or p_level < 0 or p_level > 2 then raise exception 'Unknown item'; end if;
  v_code := _gen_duel_code();
  insert into duels (code, grade, level, target, creator_id, creator_name, school_id)
    values (v_code, s.grade, p_level, v_target, s.id, s.name, s.school_id)
    returning duels.id into v_id;
  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = v_id;
end; $$;

create or replace function join_duel(p_token text, p_code text)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language plpgsql security definer as $$
declare s students; v_row duels;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select * into v_row from duels where duels.code = upper(trim(p_code));
  if not found then raise exception 'Invalid code'; end if;
  if v_row.school_id <> s.school_id then raise exception 'Invalid code'; end if;
  if v_row.creator_id = s.id then raise exception 'Invalid code'; end if;
  if v_row.status = 'waiting' then
    update duels set opponent_id = s.id, opponent_name = s.name, status = 'active'
      where duels.id = v_row.id;
  elsif v_row.opponent_id is not null and v_row.opponent_id <> s.id then
    raise exception 'Invalid code';
  end if;
  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = v_row.id;
end; $$;

-- ---------- raids: only your own school's same-grade students are targets ----------

create or replace function list_raid_targets(p_token text)
returns table(id uuid, name text, avatar text, avatar_layers jsonb, frame text,
              coins int, building_count int, cooldown_seconds int)
language plpgsql security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select st.id, st.name, st.avatar, st.avatar_layers, st.frame, st.coins,
      (select count(*)::int from jsonb_each(coalesce(st.island,'{}'::jsonb))),
      greatest(0, 600 - floor(extract(epoch from (now() -
        (select max(r.created_at) from raids r where r.attacker_id = s.id and r.defender_id = st.id and r.success)
      )))::int)
    from students st
    where st.id <> s.id and st.guest = false and st.grade = s.grade and st.school_id = s.school_id
    order by st.name;
end; $$;

create or replace function resolve_raid(p_token text, p_defender_id uuid, p_won boolean)
returns table(coins int, stolen int, wrecked boolean, defender_name text)
language plpgsql security definer as $$
declare
  s students; d students;
  v_cooldown_until timestamptz;
  v_stolen int := 0;
  v_wrecked boolean := false;
  v_key text;
  v_island jsonb;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  if p_defender_id = s.id then raise exception 'Unknown item'; end if;
  select * into d from students where students.id = p_defender_id;
  if not found then raise exception 'Unknown item'; end if;
  if d.school_id <> s.school_id then raise exception 'Unknown item'; end if;

  select max(r.created_at) + interval '10 minutes' into v_cooldown_until
    from raids r where r.attacker_id = s.id and r.defender_id = p_defender_id and r.success;
  if v_cooldown_until is not null and v_cooldown_until > now() then
    raise exception 'Too soon — wait a bit before raiding them again';
  end if;

  if coalesce(p_won,false) then
    v_stolen := floor(coalesce(d.coins,0) * 0.2);
    if v_stolen > 40 then v_stolen := 40; end if;
    if v_stolen > coalesce(d.coins,0) then v_stolen := coalesce(d.coins,0); end if;

    select key into v_key from jsonb_each(coalesce(d.island,'{}'::jsonb)) as e(key,val)
      where not coalesce((val->>'wrecked')::boolean, false)
      order by random() limit 1;

    if v_key is not null then
      v_island := d.island;
      v_island := jsonb_set(v_island, array[v_key], (v_island->v_key) || jsonb_build_object('wrecked', true));
      update students set island = v_island where students.id = d.id;
      v_wrecked := true;
    end if;

    update students set coins = students.coins - v_stolen where students.id = d.id;
    update students set coins = students.coins + v_stolen where students.id = s.id;
  end if;

  insert into raids (attacker_id, defender_id, success, coins_stolen, wrecked_key)
    values (s.id, p_defender_id, coalesce(p_won,false), v_stolen, v_key);

  return query select st.coins, v_stolen, v_wrecked, d.name from students st where st.id = s.id;
end; $$;

-- ---------- admin backup, scoped to the admin's own school ----------

create or replace function export_all(p_token text)
returns jsonb language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'school', (select to_jsonb(sc) - 'teacher_code' from schools sc where sc.id = me.school_id),
    'sections', (select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from sections s where s.school_id = me.school_id),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('name',name,'role',role)),'[]'::jsonb) from teachers where school_id = me.school_id),
    'students', (select coalesce(jsonb_agg(to_jsonb(st) - 'password_hash' - 'session_token'),'[]'::jsonb) from students st where st.school_id = me.school_id),
    'competitions', (select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from competitions c where c.school_id = me.school_id)
  );
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
