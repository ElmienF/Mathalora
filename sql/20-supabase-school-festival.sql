-- ============================================================================
-- Mathalora — School Festival (competition format #7: "students across the
-- school participate in competitions grouped by grade or skill level").
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-coin-ledger.sql.
--
-- Every other whole-school event so far (a "Class Challenge" competition
-- scoped to 'school') is one flat leaderboard. A School Festival is the
-- same idea opened up to the whole school at once, but split into several
-- side-by-side boards so a Grade 2 student isn't just buried under Grade
-- 11 points, and a festival can instead be run by skill area if a teacher
-- would rather celebrate strength across every grade in, say, Fraction
-- Lagoon. The grouping itself is computed from each student's own real,
-- already-stored `progress` and `grade` — nothing simulated — the same
-- way curriculum-standard coverage already works: this migration returns
-- the flat, real per-student rows, and the client groups them into tabs
-- client-side (same pattern as the Standards tab's strand coverage).
--
-- Like the existing whole-school Competitions, a Festival is a ranking/
-- recognition event — it doesn't mint new coins of its own. The coins and
-- points behind every ranking were already earned honestly through Solo
-- Adventure, Duels, Team Quests etc., so this keeps "all formats award
-- earned coins" true without inventing a second reward on top of it.
--
-- Safe on live data: only adds one new table. Changes nothing existing.
-- Safe to re-run.
-- ============================================================================

create table if not exists school_festivals (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  teacher_id uuid references teachers(id) on delete set null,
  name text not null default '',
  group_mode text not null check (group_mode in ('grade','skill')) default 'grade',
  status text not null check (status in ('open','done')) default 'open',
  start_date date not null default current_date,
  end_date date not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_school_festivals_school on school_festivals(school_id);

alter table school_festivals enable row level security;
revoke all on school_festivals from anon, authenticated;

-- ---------- teacher-facing: create, list, end ----------

create or replace function create_school_festival(p_token text, p_name text, p_group_mode text, p_end date)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if p_group_mode not in ('grade','skill') then raise exception 'Unknown item'; end if;
  if p_end is null or p_end < current_date then raise exception 'Invalid amount'; end if;
  insert into school_festivals(school_id, teacher_id, name, group_mode, end_date)
    values (me.school_id, me.id, left(trim(coalesce(p_name,'')),40), p_group_mode, p_end);
end; $$;

create or replace function list_school_festivals_dashboard(p_token text)
returns table(id uuid, name text, group_mode text, status text, start_date date, end_date date)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select f.id, f.name, f.group_mode, f.status, f.start_date, f.end_date
    from school_festivals f where f.school_id = me.school_id order by f.created_at desc;
end; $$;

create or replace function end_school_festival(p_token text, p_festival_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  update school_festivals set status = 'done'
    where id = p_festival_id and school_id = me.school_id;
end; $$;

-- ---------- student-facing: see what's on, view a leaderboard ----------

create or replace function list_open_school_festivals(p_token text)
returns table(id uuid, name text, group_mode text, start_date date, end_date date)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query select f.id, f.name, f.group_mode, f.start_date, f.end_date
    from school_festivals f
    where f.school_id = s.school_id and f.status = 'open' and f.end_date >= current_date
    order by f.start_date;
end; $$;

-- Works for either a signed-in student or a signed-in teacher at the same
-- school as the festival, since this is a whole-school, shared leaderboard
-- (same visibility rule as a tournament bracket or a Class Challenge board).
create or replace function festival_leaderboard(p_token text, p_festival_id uuid, p_limit int default 300)
returns table(name text, grade int, points int, progress jsonb)
language plpgsql stable security definer as $$
declare f school_festivals; v_school uuid; s students; t teachers;
begin
  select * into f from school_festivals where id = p_festival_id;
  if not found then raise exception 'Unknown item'; end if;

  s := _student_from_session(p_token);
  if s.id is not null then
    v_school := s.school_id;
  else
    t := _teacher_from_session(p_token);
    if t.id is null then raise exception 'Not signed in'; end if;
    v_school := t.school_id;
  end if;
  if v_school <> f.school_id then raise exception 'Unknown item'; end if;

  return query
    select st.name, st.grade, st.points, coalesce(st.progress,'{}'::jsonb)
    from students st
    where st.guest = false and st.school_id = f.school_id
    order by st.points desc
    limit greatest(1, least(500, coalesce(p_limit, 300)));
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
