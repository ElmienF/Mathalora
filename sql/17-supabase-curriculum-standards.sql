-- Mathalora: curriculum-strand coverage for teachers.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-tournaments.sql.
--
-- This is a small, additive change: it extends the existing list_students()
-- teacher RPC to also return each student's saved `progress` jsonb, so the
-- new "Standards" tab in the teacher dashboard can compute real curriculum
-- coverage (which islands / grade-level rounds each student has actually
-- practiced or mastered) entirely from genuine, already-stored progress —
-- no new table, no simulated or estimated data. The strand mapping itself
-- (which island maps to which maths strand) lives in the client as plain
-- display logic, same as every other content-authoring list in this app.
--
-- Safe to run again: it only replaces one function.

drop function if exists list_students(text);
create or replace function list_students(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, has_password boolean,
              coins int, progress jsonb)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select s.id, s.name, s.grade, s.section_id, sec.name, (s.password_hash is not null),
    s.coins, coalesce(s.progress, '{}'::jsonb)
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false and s.school_id = me.school_id order by s.grade nulls first, s.name;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
