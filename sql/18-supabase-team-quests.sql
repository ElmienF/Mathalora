-- ============================================================================
-- Mathalora — Team Quests (competition format #4: small teams contributing
-- to one shared goal).
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-curriculum-standards.sql.
--
-- A teacher opens a Team Quest for one grade: a team size (2-6) and a
-- shared target (e.g. "300 correct answers, together"). Students in that
-- grade join while it's open — the server slots each one into the first
-- team with room, or opens a new team once the current one fills.
--
-- There is no new quiz screen here: a team's progress is simply the real
-- sum of "correct answers" every member's own ordinary rounds and Blitz
-- runs already report back to the server (see contribute_to_team_quests,
-- called once per finished round/Blitz from the client, same as every
-- other progress save). That keeps this a genuinely shared, server-held
-- number — never a simulated or client-only tally — while reusing the
-- existing untimed/optional-speed play the student was already doing,
-- rather than inventing a separate timed team mini-game.
--
-- Once a team's progress reaches its target, every member of that team
-- gets a real coin bonus, logged the same way every other coin grant is.
--
-- Safe on live data: only adds new tables. Changes nothing existing.
-- Safe to re-run.
-- ============================================================================

create table if not exists team_quests (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  teacher_id uuid references teachers(id) on delete set null,
  name text not null default '',
  grade int not null,
  team_size int not null check (team_size between 2 and 6),
  target int not null check (target between 10 and 5000),
  status text not null default 'open' check (status in ('open','ended')),
  created_at timestamptz not null default now()
);
alter table team_quests enable row level security;
revoke all on team_quests from anon, authenticated;

create table if not exists team_quest_teams (
  id uuid primary key default gen_random_uuid(),
  quest_id uuid not null references team_quests(id) on delete cascade,
  name text not null,
  progress int not null default 0,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table team_quest_teams enable row level security;
revoke all on team_quest_teams from anon, authenticated;
create index if not exists team_quest_teams_quest_idx on team_quest_teams(quest_id);

create table if not exists team_quest_members (
  team_id uuid not null references team_quest_teams(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (team_id, student_id)
);
alter table team_quest_members enable row level security;
revoke all on team_quest_members from anon, authenticated;
create index if not exists team_quest_members_student_idx on team_quest_members(student_id);

-- ---------- teacher-facing: create, list, end ----------

create or replace function create_team_quest(p_token text, p_name text, p_grade int, p_team_size int, p_target int)
returns table(id uuid) language plpgsql security definer as $$
declare me teachers; v_id uuid;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if p_team_size is null or p_team_size < 2 or p_team_size > 6 then raise exception 'Unknown item'; end if;
  if p_target is null or p_target < 10 or p_target > 5000 then raise exception 'Unknown item'; end if;
  insert into team_quests(school_id, teacher_id, name, grade, team_size, target)
    values (me.school_id, me.id, left(trim(coalesce(p_name,'')),40), p_grade, p_team_size, p_target)
    returning team_quests.id into v_id;
  return query select v_id;
end; $$;

create or replace function list_team_quests_dashboard(p_token text)
returns table(id uuid, name text, grade int, team_size int, target int, status text,
              team_count int, member_count int, teams_completed int)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query
    select q.id, q.name, q.grade, q.team_size, q.target, q.status,
      (select count(*)::int from team_quest_teams tt where tt.quest_id = q.id),
      (select count(*)::int from team_quest_teams tt join team_quest_members m on m.team_id = tt.id where tt.quest_id = q.id),
      (select count(*)::int from team_quest_teams tt where tt.quest_id = q.id and tt.completed_at is not null)
    from team_quests q
    where q.school_id = me.school_id
    order by q.created_at desc;
end; $$;

-- Every team in one quest, each with its member names, for the teacher to
-- see progress in detail without exposing anything from another school.
create or replace function list_team_quest_teams(p_token text, p_quest_id uuid)
returns table(team_id uuid, team_name text, progress int, target int, completed_at timestamptz, members text)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query
    select tt.id, tt.name, tt.progress, q.target, tt.completed_at,
      coalesce((select string_agg(s.name, ', ' order by s.name) from team_quest_members m
                join students s on s.id = m.student_id where m.team_id = tt.id), '')
    from team_quest_teams tt
    join team_quests q on q.id = tt.quest_id
    where tt.quest_id = p_quest_id and q.school_id = me.school_id
    order by tt.created_at;
end; $$;

create or replace function end_team_quest(p_token text, p_quest_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  update team_quests set status='ended' where id = p_quest_id and school_id = me.school_id;
end; $$;

-- ---------- student-facing: see open quests, join a team, track progress ----------

create or replace function list_open_team_quests(p_token text)
returns table(id uuid, name text, grade int, team_size int, target int, joined boolean)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select q.id, q.name, q.grade, q.team_size, q.target,
      exists(select 1 from team_quest_teams tt join team_quest_members m on m.team_id = tt.id
             where tt.quest_id = q.id and m.student_id = s.id)
    from team_quests q
    where q.school_id = s.school_id and q.grade = s.grade and q.status = 'open'
    order by q.created_at desc;
end; $$;

-- Slots the student into the first team in this quest with a free seat,
-- opening a new team once the current one is full. A student can only be
-- on one team per quest (enforced by the membership primary key together
-- with the "already on a team here" check below).
create or replace function join_team_quest(p_token text, p_quest_id uuid)
returns table(team_id uuid) language plpgsql security definer as $$
declare s students; q team_quests; v_team team_quest_teams; v_count int; v_team_id uuid;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select * into q from team_quests where team_quests.id = p_quest_id and team_quests.school_id = s.school_id;
  if not found or q.status <> 'open' then raise exception 'Unknown item'; end if;
  if q.grade <> s.grade then raise exception 'Unknown item'; end if;
  if exists(select 1 from team_quest_teams tt join team_quest_members m on m.team_id = tt.id
            where tt.quest_id = p_quest_id and m.student_id = s.id) then
    raise exception 'Already joined';
  end if;

  select tt.* into v_team from team_quest_teams tt
    where tt.quest_id = p_quest_id and tt.completed_at is null
    order by tt.created_at
    for update skip locked;
  if found then
    select count(*) into v_count from team_quest_members m where m.team_id = v_team.id;
  end if;
  if not found or v_count >= q.team_size then
    insert into team_quest_teams(quest_id, name)
      values (p_quest_id, 'Team ' || ((select count(*) from team_quest_teams where quest_id = p_quest_id) + 1))
      returning team_quest_teams.id into v_team_id;
  else
    v_team_id := v_team.id;
  end if;

  insert into team_quest_members(team_id, student_id) values (v_team_id, s.id) on conflict do nothing;
  return query select v_team_id;
end; $$;

create or replace function leave_team_quest(p_token text, p_quest_id uuid)
returns void language plpgsql security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  delete from team_quest_members m using team_quest_teams tt
    where m.team_id = tt.id and tt.quest_id = p_quest_id and m.student_id = s.id and tt.completed_at is null;
end; $$;

-- Every quest I've joined, with my own team's progress and teammates.
create or replace function my_team_quests(p_token text)
returns table(quest_id uuid, quest_name text, grade int, target int, status text,
              team_id uuid, team_name text, progress int, completed_at timestamptz, teammates text)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select q.id, q.name, q.grade, q.target, q.status, tt.id, tt.name, tt.progress, tt.completed_at,
      coalesce((select string_agg(s2.name, ', ' order by s2.name) from team_quest_members m2
                join students s2 on s2.id = m2.student_id where m2.team_id = tt.id and s2.id <> s.id), '')
    from team_quest_members m
    join team_quest_teams tt on tt.id = m.team_id
    join team_quests q on q.id = tt.quest_id
    where m.student_id = s.id
    order by q.created_at desc;
end; $$;

-- Called once after every finished round/Blitz (any grade, any level) to
-- add that round's real correct-answer count to every team this student
-- is currently on, across every quest still open. A no-op if the student
-- isn't on any team. When a team's progress reaches its target, every
-- member gets a real, logged coin bonus — once, the moment it happens.
create or replace function contribute_to_team_quests(p_token text, p_amount int)
returns void language plpgsql security definer as $$
declare s students; v_amount int; r record; v_newprog int;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  v_amount := greatest(0, least(200, coalesce(p_amount,0)));
  if v_amount = 0 then return; end if;

  for r in
    select tt.id as team_id, tt.quest_id, q.target
    from team_quest_members m
    join team_quest_teams tt on tt.id = m.team_id
    join team_quests q on q.id = tt.quest_id
    where m.student_id = s.id and q.status = 'open' and tt.completed_at is null
  loop
    update team_quest_teams set progress = least(r.target, progress + v_amount)
      where id = r.team_id
      returning progress into v_newprog;
    if v_newprog >= r.target then
      update team_quest_teams set completed_at = now() where id = r.team_id and completed_at is null;
      update students set coins = coins + 25
        where id in (select student_id from team_quest_members where team_id = r.team_id);
      insert into coin_grants(student_id, teacher_id, amount, note)
        select student_id, null, 25, 'Team Quest goal reached'
        from team_quest_members where team_id = r.team_id;
    end if;
  end loop;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
