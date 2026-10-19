-- ============================================================================
-- Add the ability to assign/change a student's class after they've already
-- been added. Run this once in the Supabase SQL Editor, any time after
-- supabase-bloom-island-complete.sql. Safe on live data — only adds one
-- new function, touches no existing data.
-- ============================================================================

create or replace function set_student_section(p_token text, p_student_id uuid, p_section_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null or me.role <> 'admin' then raise exception 'Admins only'; end if;
  update students set section_id = p_section_id where id = p_student_id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
