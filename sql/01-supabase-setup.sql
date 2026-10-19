-- ============================================================================
-- Mathalora — Supabase setup
-- Run this ONCE in Supabase: Project -> SQL Editor -> New query -> paste -> Run
-- Safe to re-run from scratch only on a brand new project (it creates tables;
-- it will error if they already exist, which is fine / expected on a re-run).
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------- tables ----------

create table app_config (
  id int primary key default 1,
  school_name text not null default 'Mathalora School',
  student_code text,
  teacher_code text not null,
  constraint single_row check (id = 1)
);

create table teachers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text not null check (role in ('admin','teacher')),
  password_hash text,
  session_token text unique,
  session_expires timestamptz,
  created_at timestamptz not null default now()
);

create table sections (
  id uuid primary key default gen_random_uuid(),
  grade int not null check (grade between 1 and 12),
  name text not null,
  code text,
  created_at timestamptz not null default now()
);

create table students (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  grade int,
  section_id uuid references sections(id) on delete set null,
  avatar text,
  password_hash text,
  guest boolean not null default false,
  points int not null default 0,
  progress jsonb not null default '{}'::jsonb,
  blitz jsonb not null default '{}'::jsonb,
  last_grade int,
  session_token text unique,
  session_expires timestamptz,
  created_at timestamptz not null default now()
);

create table competitions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  scope_type text not null check (scope_type in ('school','grade','section')),
  scope_grade int,
  scope_section_id uuid references sections(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  created_at timestamptz not null default now()
);

-- seed: one admin account (password set on first login) + a fixed staff code
insert into app_config (id, school_name, student_code, teacher_code)
values (1, 'Mathalora School', null, '97M7YQ');

insert into teachers (name, role, password_hash)
values ('Admin', 'admin', null);

-- ---------- lock every table down; the app only ever talks through the
-- functions below (SECURITY DEFINER), never directly to these tables ----------

alter table app_config enable row level security;
alter table teachers enable row level security;
alter table sections enable row level security;
alter table students enable row level security;
alter table competitions enable row level security;
-- (no policies are created, and anon/authenticated have no table grants below,
--  so direct REST/table access is denied; only the functions can touch them)

revoke all on app_config, teachers, sections, students, competitions from anon, authenticated;

-- ---------- helpers ----------

create or replace function _new_token() returns text
language sql volatile as $$
  select encode(gen_random_bytes(24), 'hex');
$$;

create or replace function _teacher_from_session(p_token text)
returns teachers language sql stable as $$
  select * from teachers
  where session_token = p_token and session_expires > now();
$$;

create or replace function _student_from_session(p_token text)
returns students language sql stable as $$
  select * from students
  where session_token = p_token and session_expires > now();
$$;

-- ============================================================================
-- PUBLIC (no login needed yet) — used by the gate / join screens
-- ============================================================================

create or replace function public_config()
returns table(school_name text, has_student_code boolean)
language sql stable security definer as $$
  select school_name, (student_code is not null) from app_config where id = 1;
$$;

-- Student enters a class or whole-school code; returns the scoped roster.
-- Never exposes password_hash.
create or replace function student_join(p_code text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, has_password boolean)
language plpgsql stable security definer as $$
declare v_code text := upper(trim(p_code)); v_section sections;
begin
  if v_code = '' then raise exception 'Invalid code'; end if;
  if exists(select 1 from app_config where id=1 and upper(student_code) = v_code) then
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

-- First-time: claim a roster name with an avatar + new password.
create or replace function student_claim(p_student_id uuid, p_avatar text, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean)
language plpgsql security definer as $$
declare v_token text;
begin
  if length(p_password) < 4 then raise exception 'Password too short'; end if;
  if not exists(select 1 from students where id=p_student_id and password_hash is null) then
    raise exception 'Already claimed';
  end if;
  v_token := _new_token();
  update students set avatar = p_avatar, password_hash = crypt(p_password, gen_salt('bf')),
    session_token = v_token, session_expires = now() + interval '30 days'
  where students.id = p_student_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

create or replace function student_login(p_student_id uuid, p_password text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean)
language plpgsql security definer as $$
declare v_token text; v_ok boolean;
begin
  select (password_hash is not null and password_hash = crypt(p_password, password_hash))
    into v_ok from students where id = p_student_id;
  if not coalesce(v_ok,false) then raise exception 'Wrong password'; end if;
  v_token := _new_token();
  update students set session_token = v_token, session_expires = now() + interval '30 days'
  where id = p_student_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest
  from students s left join sections sec on sec.id = s.section_id where s.id = p_student_id;
end; $$;

-- Guest ("just try it out") — no code, no password, this device only.
create or replace function guest_start(p_name text)
returns table(session_token text, id uuid, name text, grade int, section_id uuid, section_name text,
              avatar text, points int, progress jsonb, blitz jsonb, last_grade int, guest boolean)
language plpgsql security definer as $$
declare v_id uuid; v_token text := _new_token();
begin
  insert into students (name, guest, session_token, session_expires)
  values (left(trim(p_name),16), true, v_token, now() + interval '30 days')
  returning id into v_id;
  return query select v_token, s.id, s.name, s.grade, s.section_id, null::text, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest from students s where s.id=v_id;
end; $$;

create or replace function student_session(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, avatar text,
              points int, progress jsonb, blitz jsonb, last_grade int, guest boolean)
language plpgsql security definer as $$
begin
  update students set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest
  from students s left join sections sec on sec.id = s.section_id
  where s.session_token = p_token and s.session_expires > now();
end; $$;

-- Save progress after a round/blitz. Points accumulate atomically; progress/blitz
-- are shallow-merged (the client sends only the keys that changed).
create or replace function student_save_progress(p_token text, p_points_delta int,
  p_progress_patch jsonb, p_blitz_patch jsonb, p_last_grade int)
returns table(points int, progress jsonb, blitz jsonb)
language plpgsql security definer as $$
begin
  update students set
    points = points + coalesce(p_points_delta,0),
    progress = progress || coalesce(p_progress_patch,'{}'::jsonb),
    blitz = blitz || coalesce(p_blitz_patch,'{}'::jsonb),
    last_grade = coalesce(p_last_grade, last_grade),
    session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.points, s.progress, s.blitz from students s where s.session_token = p_token;
end; $$;

create or replace function student_reset_progress(p_token text)
returns void language plpgsql security definer as $$
begin
  update students set points=0, progress='{}'::jsonb, blitz='{}'::jsonb
  where session_token = p_token and session_expires > now();
end; $$;

create or replace function guest_delete(p_token text)
returns void language plpgsql security definer as $$
begin
  delete from students where session_token = p_token and guest = true;
end; $$;

create or replace function student_logout(p_token text)
returns void language plpgsql security definer as $$
begin
  update students set session_token = null, session_expires = null where session_token = p_token;
end; $$;

-- Competitions + mini leaderboard a student's home screen can see (low-sensitivity:
-- just names + point totals, so this is intentionally public given grade/section).
create or replace function competitions_for(p_grade int, p_section_id uuid)
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language sql stable security definer as $$
  select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
  from competitions c
  where c.end_date >= current_date and (
    c.scope_type = 'school'
    or (c.scope_type = 'grade' and c.scope_grade = p_grade)
    or (c.scope_type = 'section' and c.scope_section_id = p_section_id)
  )
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
    where s.guest = false and (
      c.scope_type = 'school'
      or (c.scope_type = 'grade' and s.grade = c.scope_grade)
      or (c.scope_type = 'section' and s.section_id = c.scope_section_id)
    )
    order by s.points desc limit p_limit;
end; $$;

-- ============================================================================
-- STAFF — code gate, then pick-name, then set/enter password (mirrors students)
-- ============================================================================

create or replace function teacher_join(p_code text)
returns table(id uuid, name text, role text, has_password boolean)
language plpgsql stable security definer as $$
begin
  if not exists(select 1 from app_config where id=1 and upper(teacher_code) = upper(trim(p_code))) then
    raise exception 'Invalid code';
  end if;
  return query select t.id, t.name, t.role, (t.password_hash is not null) from teachers t order by t.name;
end; $$;

create or replace function teacher_logout(p_token text)
returns void language plpgsql security definer as $$
begin
  update teachers set session_token = null, session_expires = null where session_token = p_token;
end; $$;

create or replace function teacher_claim(p_teacher_id uuid, p_password text)
returns table(session_token text, id uuid, name text, role text)
language plpgsql security definer as $$
declare v_token text;
begin
  if length(p_password) < 4 then raise exception 'Password too short'; end if;
  if not exists(select 1 from teachers where id=p_teacher_id and password_hash is null) then
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
    into v_ok from teachers where id = p_teacher_id;
  if not coalesce(v_ok,false) then raise exception 'Wrong password'; end if;
  v_token := _new_token();
  update teachers set session_token = v_token, session_expires = now() + interval '30 days'
  where id = p_teacher_id;
  return query select v_token, t.id, t.name, t.role from teachers t where t.id = p_teacher_id;
end; $$;

create or replace function teacher_session(p_token text)
returns table(id uuid, name text, role text)
language plpgsql security definer as $$
begin
  update teachers set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select t.id, t.name, t.role from teachers t
    where t.session_token = p_token and t.session_expires > now();
end; $$;

-- ---------- dashboard reads (any signed-in teacher or admin) ----------

create or replace function list_sections(p_token text)
returns table(id uuid, grade int, name text, code text, student_count bigint)
language plpgsql stable security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select sec.id, sec.grade, sec.name, sec.code,
    (select count(*) from students st where st.section_id = sec.id)
    from sections sec order by sec.grade, sec.name;
end; $$;

create or replace function list_students(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, has_password boolean)
language plpgsql stable security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select s.id, s.name, s.grade, s.section_id, sec.name, (s.password_hash is not null)
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false order by s.grade nulls first, s.name;
end; $$;

create or replace function list_teachers(p_token text)
returns table(id uuid, name text, role text, has_password boolean, is_me boolean)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select t.id, t.name, t.role, (t.password_hash is not null), (t.id = me.id)
    from teachers t order by t.name;
end; $$;

create or replace function list_competitions(p_token text)
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language plpgsql stable security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
    from competitions c order by c.start_date;
end; $$;

create or replace function get_codes(p_token text)
returns table(school_name text, student_code text, teacher_code text)
language plpgsql stable security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select a.school_name, a.student_code, a.teacher_code from app_config a where id=1;
end; $$;

-- ---------- dashboard writes: any teacher (classes, codes, competitions) ----------

create or replace function save_school_name(p_token text, p_name text)
returns void language plpgsql security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  update app_config set school_name = left(trim(p_name),40) where id=1;
end; $$;

create or replace function new_student_code(p_token text)
returns text language plpgsql security definer as $$
declare v text;
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update app_config set student_code = v where id=1;
  return v;
end; $$;

create or replace function add_section(p_token text, p_grade int, p_name text)
returns void language plpgsql security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  if exists(select 1 from sections where grade=p_grade and lower(name)=lower(trim(p_name))) then return; end if;
  insert into sections(grade,name) values (p_grade, left(trim(p_name),20));
end; $$;

create or replace function delete_section(p_token text, p_section_id uuid)
returns void language plpgsql security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  update students set section_id = null where section_id = p_section_id;
  delete from sections where id = p_section_id;
end; $$;

create or replace function new_section_code(p_token text, p_section_id uuid)
returns text language plpgsql security definer as $$
declare v text;
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update sections set code = v where id = p_section_id;
  return v;
end; $$;

create or replace function add_competition(p_token text, p_name text, p_scope_type text,
  p_scope_grade int, p_scope_section_id uuid, p_start date, p_end date)
returns void language plpgsql security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  insert into competitions(name,scope_type,scope_grade,scope_section_id,start_date,end_date)
  values (left(trim(p_name),40), p_scope_type, p_scope_grade, p_scope_section_id, p_start, p_end);
end; $$;

create or replace function delete_competition(p_token text, p_competition_id uuid)
returns void language plpgsql security definer as $$
begin
  if (_teacher_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  delete from competitions where id = p_competition_id;
end; $$;

-- ---------- dashboard writes: ADMIN ONLY (accounts + student roster) ----------

create or replace function new_teacher_code(p_token text)
returns text language plpgsql security definer as $$
declare me teachers; v text;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  v := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
  update app_config set teacher_code = v where id=1;
  return v;
end; $$;

create or replace function add_teacher(p_token text, p_name text, p_role text)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  if exists(select 1 from teachers where lower(name)=lower(trim(p_name))) then
    raise exception 'Name already used';
  end if;
  insert into teachers(name, role) values (left(trim(p_name),30), case when p_role='admin' then 'admin' else 'teacher' end);
end; $$;

create or replace function remove_teacher(p_token text, p_teacher_id uuid)
returns void language plpgsql security definer as $$
declare me teachers; v_role text; v_count int; v_admins int;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  select count(*) into v_count from teachers;
  if v_count <= 1 then raise exception 'Cannot remove the last account'; end if;
  select role into v_role from teachers where id = p_teacher_id;
  select count(*) into v_admins from teachers where role = 'admin';
  if v_role = 'admin' and v_admins <= 1 then raise exception 'Cannot remove the last admin'; end if;
  delete from teachers where id = p_teacher_id;
end; $$;

create or replace function add_student(p_token text, p_name text, p_grade int, p_section_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  insert into students(name, grade, section_id) values (left(trim(p_name),24), p_grade, p_section_id);
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
      select id into v_section_id from sections where grade=v_grade and lower(name)=lower(v_secname);
      if v_section_id is null then
        insert into sections(grade,name) values (v_grade, left(v_secname,20)) returning id into v_section_id;
      end if;
    end if;
    insert into students(name, grade, section_id) values (left(v_name,24), v_grade, v_section_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end; $$;

create or replace function remove_student(p_token text, p_student_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  delete from students where id = p_student_id;
end; $$;

-- Admin-only full export, for the "Download backup" button (a JSON safety copy).
create or replace function export_all(p_token text)
returns jsonb language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'config', (select to_jsonb(a) - 'teacher_code' from app_config a where id=1),
    'sections', (select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from sections s),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('name',name,'role',role)),'[]'::jsonb) from teachers),
    'students', (select coalesce(jsonb_agg(to_jsonb(st) - 'password_hash' - 'session_token'),'[]'::jsonb) from students st),
    'competitions', (select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from competitions c)
  );
end; $$;

-- ---------- let the anon (publishable-key) role call these functions ----------
grant execute on all functions in schema public to anon, authenticated;
