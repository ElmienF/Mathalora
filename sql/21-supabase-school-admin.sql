-- ============================================================================
-- Mathalora — platform admin: rename a school, delete a school, and enter a
-- school's own dashboard with full admin rights.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-school-festival.sql.
--
-- The platform admin console could add a school (add_school, from
-- supabase-multitenant-01.sql) but had no way to rename one, remove one, or
-- actually manage what's inside one — the "Schools" list was read-only, and
-- the ONLY way to add teachers/classes/students at a school was to be given
-- that school's staff code and claim its seeded "Admin" account by hand.
-- This adds the three missing RPCs:
--
--   1. update_school(p_token, p_school_id, p_name) — renames a school.
--      Platform-admin only. Does not touch the slug or either join code,
--      so nothing anyone already has (QR codes, printed codes, bookmarked
--      links) breaks because of a rename.
--
--   2. delete_school(p_token, p_school_id) — permanently deletes a school
--      and everything in it (teachers, sections, students, their progress
--      and coins, competitions, duels, tournaments, team quests, school
--      festivals, raids, presence). This is real, irreversible data loss —
--      the client is expected to make the person confirm before calling
--      this. Every one of those tables already has school_id (or a path
--      to it through student_id/teacher_id) declared "on delete cascade"
--      — see supabase-multitenant-01.sql, supabase-multitenant-02.sql,
--      supabase-tournaments.sql, supabase-team-quests.sql and
--      supabase-school-festival.sql — so one delete from `schools` is
--      enough; Postgres removes the rest.
--
--   3. platform_admin_enter_school(p_token, p_school_id) — gives a platform
--      admin a live teacher session for that school's own seeded "Admin"
--      account (the one add_school already created), with the exact same
--      full rights that school's real admin has: add/edit/remove classes,
--      students and staff, see Standards, run competitions — the entire
--      already-built, already-tested teacher dashboard, reused as-is rather
--      than rebuilding a second copy of it. It never touches a password —
--      it mints a fresh session token the same way teacher_login/
--      teacher_claim do, so a school whose admin has already set a password
--      keeps that password untouched. If a school somehow has no admin-role
--      teacher (shouldn't happen — add_school always seeds one), it creates
--      one rather than failing.
--
-- Safe on live data: adds no tables or columns, only three new functions.
-- ============================================================================

create or replace function update_school(p_token text, p_school_id uuid, p_name text)
returns table(id uuid, name text, slug text, teacher_code text)
language plpgsql security definer as $$
declare v_name text := trim(p_name);
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  if v_name = '' then raise exception 'School name cannot be empty'; end if;
  if not exists(select 1 from schools where schools.id = p_school_id) then
    raise exception 'Unknown school';
  end if;
  update schools set name = left(v_name, 60) where schools.id = p_school_id;
  return query select sc.id, sc.name, sc.slug, sc.teacher_code from schools sc where sc.id = p_school_id;
end; $$;

create or replace function delete_school(p_token text, p_school_id uuid)
returns void
language plpgsql security definer as $$
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  if not exists(select 1 from schools where schools.id = p_school_id) then
    raise exception 'Unknown school';
  end if;
  delete from schools where schools.id = p_school_id;
end; $$;

create or replace function platform_admin_enter_school(p_token text, p_school_id uuid)
returns table(session_token text, id uuid, name text, role text)
language plpgsql security definer as $$
declare v_token text; v_teacher_id uuid;
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  if not exists(select 1 from schools where schools.id = p_school_id) then
    raise exception 'Unknown school';
  end if;

  select t.id into v_teacher_id from teachers t
    where t.school_id = p_school_id and t.role = 'admin'
    order by t.created_at asc limit 1;

  if v_teacher_id is null then
    insert into teachers(school_id, name, role) values (p_school_id, 'Admin', 'admin')
    returning teachers.id into v_teacher_id;
  end if;

  v_token := _new_token();
  update teachers set session_token = v_token, session_expires = now() + interval '30 days'
  where teachers.id = v_teacher_id;

  return query select v_token, t.id, t.name, t.role from teachers t where t.id = v_teacher_id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
