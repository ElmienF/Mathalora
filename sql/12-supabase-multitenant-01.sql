-- ============================================================================
-- Mathalora — multi-tenant platform, part 1: schema + core auth gate.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-kg-grades.sql
-- (the 13th file in the lineage).
--
-- What this does:
--   1. Introduces `schools` (replaces the single-row `app_config`) and
--      `platform_admins` (a brand-new top tier that is not tied to any
--      one school — it creates/manages schools).
--   2. Adds school_id to teachers, sections, students, competitions and
--      backfills every existing row into one school: your current
--      Mathalora School, keeping its existing teacher_code/student_code
--      as that school's own codes.
--   3. Adds a short `school_slug` gate in front of the existing
--      teacher/student code gate, so the app can tell which school a
--      person is signing into before it ever looks at a teacher or
--      student code. Existing codes keep working exactly as before —
--      only now they're scoped to their own school, so a code typed at
--      the wrong school's gate is correctly rejected.
--   4. Rewrites the core identity functions (teacher_join/login/session,
--      student_join/login/session, guest_start, add_student, add_teacher,
--      list_students, list_sections, list_teachers, bulk_add_students)
--      to be school-scoped end to end, including a platform_admin-only
--      add_school function. Every other existing function (competitions,
--      avatars, presence, duels, raids, big builds) still runs exactly as
--      it did against the one pre-existing school and is NOT yet
--      school-scoped — that is the deliberately separate follow-up pass
--      (part 2), so nothing here breaks what's already live.
--
-- Non-destructive: existing data is migrated in place, not deleted.
-- Safe to re-run.
-- ============================================================================

-- ---------- 1. new tables ----------

create table if not exists schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,          -- short public code, e.g. "7F3QK2" — the new first gate
  student_code text,
  teacher_code text not null,
  created_at timestamptz not null default now()
);
alter table schools enable row level security;
revoke all on schools from anon, authenticated;

create table if not exists platform_admins (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  password_hash text,
  session_token text unique,
  session_expires timestamptz,
  created_at timestamptz not null default now()
);
alter table platform_admins enable row level security;
revoke all on platform_admins from anon, authenticated;

-- ---------- 2. backfill: migrate the single app_config row into schools ----------

do $$
declare v_school_id uuid; v_slug text;
begin
  if exists (select 1 from app_config where id = 1)
     and not exists (select 1 from schools) then
    v_slug := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
    insert into schools (name, slug, student_code, teacher_code)
    select school_name, v_slug, student_code, teacher_code from app_config where id = 1
    returning id into v_school_id;

    alter table teachers add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table sections add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table students add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table competitions add column if not exists school_id uuid references schools(id) on delete cascade;

    update teachers set school_id = v_school_id where school_id is null;
    update sections set school_id = v_school_id where school_id is null;
    update students set school_id = v_school_id where school_id is null;
    update competitions set school_id = v_school_id where school_id is null;
  else
    -- columns may still need adding even if schools already has rows
    -- (e.g. a re-run after a partial failure)
    alter table teachers add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table sections add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table students add column if not exists school_id uuid references schools(id) on delete cascade;
    alter table competitions add column if not exists school_id uuid references schools(id) on delete cascade;
  end if;
end $$;

-- From here on, school_id is required on every row of these four tables.
alter table teachers alter column school_id set not null;
alter table sections alter column school_id set not null;
alter table students alter column school_id set not null;
alter table competitions alter column school_id set not null;

create index if not exists idx_teachers_school on teachers(school_id);
create index if not exists idx_sections_school on sections(school_id);
create index if not exists idx_students_school on students(school_id);
create index if not exists idx_competitions_school on competitions(school_id);

-- ---------- 3. helpers ----------

create or replace function _platform_admin_from_session(p_token text)
returns platform_admins language sql stable as $$
  select * from platform_admins
  where session_token = p_token and session_expires > now();
$$;

-- The functions below change argument lists (adding p_school_id) or return
-- columns (get_codes), which create or replace cannot do in place — drop the
-- old shapes first so nothing is left as a confusing stale overload.
drop function if exists teacher_join(text);
drop function if exists student_join(text);
drop function if exists guest_start(text);
drop function if exists get_codes(text);

-- ---------- 4. PUBLIC: school gate (new first step) ----------

create or replace function school_lookup(p_slug text)
returns table(id uuid, name text, has_student_code boolean)
language sql stable security definer as $$
  select id, name, (student_code is not null) from schools
  where upper(slug) = upper(trim(p_slug));
$$;

-- kept for the existing single-school flow some older clients may still call —
-- now returns the FIRST school only, as a soft-landing fallback, and is
-- superseded by school_lookup() + the functions below which all take p_school_id.
create or replace function public_config()
returns table(school_name text, has_student_code boolean)
language sql stable security definer as $$
  select name, (student_code is not null) from schools order by created_at limit 1;
$$;

-- ---------- 5. student auth, now school-scoped ----------

create or replace function student_join(p_school_id uuid, p_code text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, has_password boolean)
language plpgsql stable security definer as $$
declare v_code text := upper(trim(p_code)); v_section sections;
begin
  if v_code = '' then raise exception 'Invalid code'; end if;
  if exists(select 1 from schools where schools.id=p_school_id and upper(student_code) = v_code) then
    return query
      select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, (s.password_hash is not null)
      from students s left join sections sec on sec.id = s.section_id
      where s.guest = false and s.school_id = p_school_id
      order by s.name;
    return;
  end if;
  select * into v_section from sections where upper(code) = v_code and school_id = p_school_id limit 1;
  if not found then raise exception 'Invalid code'; end if;
  return query
    select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, (s.password_hash is not null)
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false and s.school_id = p_school_id and s.section_id = v_section.id
    order by s.name;
end; $$;

-- student_claim / student_login / student_session / student_save_progress / student_reset_progress /
-- guest_delete / student_logout are unchanged below (a session_token already pins the
-- student to the row they claimed, which already carries school_id — no school_id
-- parameter is needed for anything keyed off an existing session).

create or replace function guest_start(p_school_id uuid, p_name text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb)
language plpgsql security definer as $$
declare v_id uuid; v_token text := _new_token();
begin
  if not exists(select 1 from schools where schools.id = p_school_id) then raise exception 'Unknown school'; end if;
  insert into students (name, guest, school_id, session_token, session_expires)
  values (left(trim(p_name),16), true, p_school_id, v_token, now() + interval '30 days')
  returning students.id into v_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, null::text, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers
  from students s where s.id=v_id;
end; $$;

-- ---------- 6. teacher/admin auth, now school-scoped ----------

create or replace function teacher_join(p_school_id uuid, p_code text)
returns table(id uuid, name text, role text, has_password boolean)
language plpgsql stable security definer as $$
begin
  if not exists(select 1 from schools where schools.id=p_school_id and upper(teacher_code) = upper(trim(p_code))) then
    raise exception 'Invalid code';
  end if;
  return query select t.id, t.name, t.role, (t.password_hash is not null)
    from teachers t where t.school_id = p_school_id order by t.name;
end; $$;

-- teacher_claim / teacher_login / teacher_session are unchanged — already keyed
-- off a teacher_id/session_token whose row carries school_id.

-- ---------- 7. dashboard reads/writes, now filtered to the caller's own school ----------

create or replace function list_sections(p_token text)
returns table(id uuid, grade int, name text, code text, student_count bigint)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select sec.id, sec.grade, sec.name, sec.code,
    (select count(*) from students st where st.section_id = sec.id)
    from sections sec where sec.school_id = me.school_id order by sec.grade, sec.name;
end; $$;

drop function if exists list_students(text);
create or replace function list_students(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, has_password boolean,
              coins int)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select s.id, s.name, s.grade, s.section_id, sec.name, (s.password_hash is not null),
    s.coins
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false and s.school_id = me.school_id order by s.grade nulls first, s.name;
end; $$;

create or replace function list_teachers(p_token text)
returns table(id uuid, name text, role text, has_password boolean, is_me boolean)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select t.id, t.name, t.role, (t.password_hash is not null), (t.id = me.id)
    from teachers t where t.school_id = me.school_id order by t.name;
end; $$;

create or replace function add_section(p_token text, p_grade int, p_name text)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if exists(select 1 from sections where school_id=me.school_id and grade=p_grade and lower(name)=lower(trim(p_name))) then return; end if;
  insert into sections(school_id, grade,name) values (me.school_id, p_grade, left(trim(p_name),20));
end; $$;

create or replace function add_student(p_token text, p_name text, p_grade int, p_section_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  insert into students(school_id, name, grade, section_id) values (me.school_id, left(trim(p_name),24), p_grade, p_section_id);
end; $$;

create or replace function bulk_add_students(p_token text, p_rows jsonb)
returns int language plpgsql security definer as $$
declare me teachers; r jsonb; v_name text; v_grade int; v_secname text; v_section_id uuid; v_count int := 0;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_name := trim(r->>'name'); if v_name = '' or v_name is null then continue; end if;
    v_grade := nullif(r->>'grade','')::int;
    v_secname := nullif(trim(r->>'section'),'');
    v_section_id := null;
    if v_secname is not null and v_grade is not null then
      select id into v_section_id from sections where school_id=me.school_id and grade=v_grade and lower(name)=lower(v_secname);
      if v_section_id is null then
        insert into sections(school_id, grade,name) values (me.school_id, v_grade, left(v_secname,20)) returning id into v_section_id;
      end if;
    end if;
    insert into students(school_id, name, grade, section_id) values (me.school_id, left(v_name,24), v_grade, v_section_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end; $$;

create or replace function add_teacher(p_token text, p_name text, p_role text)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  if exists(select 1 from teachers where school_id=me.school_id and lower(name)=lower(trim(p_name))) then
    raise exception 'Name already used';
  end if;
  insert into teachers(school_id, name, role) values (me.school_id, left(trim(p_name),30), case when p_role='admin' then 'admin' else 'teacher' end);
end; $$;

create or replace function remove_teacher(p_token text, p_teacher_id uuid)
returns void language plpgsql security definer as $$
declare me teachers; v_role text; v_count int; v_admins int;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  select count(*) into v_count from teachers where school_id = me.school_id;
  if v_count <= 1 then raise exception 'Cannot remove the last account'; end if;
  select role into v_role from teachers where id = p_teacher_id and school_id = me.school_id;
  if v_role is null then raise exception 'Not found'; end if;
  select count(*) into v_admins from teachers where role = 'admin' and school_id = me.school_id;
  if v_role = 'admin' and v_admins <= 1 then raise exception 'Cannot remove the last admin'; end if;
  delete from teachers where id = p_teacher_id and school_id = me.school_id;
end; $$;

create or replace function remove_student(p_token text, p_student_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  delete from students where id = p_student_id and school_id = me.school_id;
end; $$;

create or replace function new_student_code(p_token text)
returns text language plpgsql security definer as $$
declare me teachers; v text;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update schools set student_code = v where id = me.school_id;
  return v;
end; $$;

create or replace function new_teacher_code(p_token text)
returns text language plpgsql security definer as $$
declare me teachers; v text;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update schools set teacher_code = v where id = me.school_id;
  return v;
end; $$;

create or replace function get_codes(p_token text)
returns table(school_name text, school_slug text, student_code text, teacher_code text)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select sc.name, sc.slug, sc.student_code, sc.teacher_code from schools sc where sc.id = me.school_id;
end; $$;

create or replace function save_school_name(p_token text, p_name text)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  update schools set name = left(trim(p_name),40) where id = me.school_id;
end; $$;

-- ---------- 8. platform admin: create new schools ----------

create or replace function platform_admin_login(p_name text, p_password text)
returns table(session_token text, id uuid, name text)
language plpgsql security definer as $$
declare v_token text; v_ok boolean; v_id uuid;
begin
  select platform_admins.id, (platform_admins.password_hash is not null and platform_admins.password_hash = crypt(p_password, platform_admins.password_hash))
    into v_id, v_ok from platform_admins where lower(platform_admins.name) = lower(trim(p_name));
  if not coalesce(v_ok,false) then raise exception 'Wrong name or password'; end if;
  v_token := _new_token();
  update platform_admins set session_token = v_token, session_expires = now() + interval '30 days'
  where platform_admins.id = v_id;
  return query select v_token, pa.id, pa.name from platform_admins pa where pa.id = v_id;
end; $$;

create or replace function platform_admin_session(p_token text)
returns table(id uuid, name text)
language plpgsql security definer as $$
begin
  update platform_admins set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select pa.id, pa.name from platform_admins pa
    where pa.session_token = p_token and pa.session_expires > now();
end; $$;

create or replace function list_schools(p_token text)
returns table(id uuid, name text, slug text, teacher_count bigint, student_count bigint, created_at timestamptz)
language plpgsql stable security definer as $$
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select sc.id, sc.name, sc.slug,
    (select count(*) from teachers t where t.school_id = sc.id),
    (select count(*) from students st where st.school_id = sc.id and st.guest = false),
    sc.created_at
  from schools sc order by sc.created_at;
end; $$;

create or replace function add_school(p_token text, p_name text)
returns table(id uuid, name text, slug text, teacher_code text)
language plpgsql security definer as $$
declare v_slug text; v_tcode text; v_id uuid;
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  v_slug := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  v_tcode := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  insert into schools(name, slug, teacher_code) values (left(trim(p_name),60), v_slug, v_tcode)
  returning schools.id into v_id;
  -- every new school starts with one unclaimed admin account, same as the original single-school seed
  insert into teachers(school_id, name, role) values (v_id, 'Admin', 'admin');
  return query select sc.id, sc.name, sc.slug, sc.teacher_code from schools sc where sc.id = v_id;
end; $$;

-- ---------- 9. grants ----------

grant execute on all functions in schema public to anon, authenticated;
