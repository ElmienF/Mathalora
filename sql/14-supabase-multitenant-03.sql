-- ============================================================================
-- Mathalora — multi-tenant platform, part 3: a "pick your school" step for
-- the public gate screen. Run this ONCE in the Supabase SQL Editor, AFTER
-- supabase-multitenant-02.sql.
--
-- Parts 1 and 2 scoped every RPC to a school_id, but nothing in the client
-- had a way to find out WHICH school it was talking to before someone
-- logged in — the gate screen, the "join your class" and "staff sign-in"
-- flows all silently assumed "the first school in the table". That's fine
-- (and unchanged) for the common case of one school. This file adds the one
-- new public function the client needs to handle a second school: it tells
-- the client whether there's more than one school at all, so the app can
-- show a tiny "which school?" step only when it's actually needed, and stay
-- exactly as it is today otherwise.
--
-- Safe on live data: adds one new function and one new overload. Changes
-- nothing existing. Safe to re-run.
-- ============================================================================

-- Replaces the public_config() call the gate screen used to make. Same
-- shape, plus the school's own id (so the client can pass it into
-- guest_start/student_join/teacher_join) and a multi_school flag (so the
-- client only bothers showing a school picker when there's more than one
-- school to choose between).
create or replace function public_school_info()
returns table(id uuid, name text, has_student_code boolean, multi_school boolean)
language sql stable security definer as $$
  select sc.id, sc.name, (sc.student_code is not null),
    (select count(*) from schools) > 1
  from schools sc order by sc.created_at limit 1;
$$;

-- Same as the existing no-arg competitions_for_gate(), but scoped to a
-- specific school once the client knows which one it's at (from
-- public_school_info() or school_lookup()). The no-arg version stays as
-- the fallback for a caller that hasn't been updated.
create or replace function competitions_for_gate(p_school_id uuid)
returns table(id uuid, name text, scope_type text, scope_grade int, scope_section_id uuid,
              start_date date, end_date date)
language sql stable security definer as $$
  select c.id, c.name, c.scope_type, c.scope_grade, c.scope_section_id, c.start_date, c.end_date
  from competitions c
  where c.scope_type = 'school' and c.end_date >= current_date and c.school_id = p_school_id
  order by c.start_date;
$$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
