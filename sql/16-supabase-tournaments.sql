-- ============================================================================
-- Mathalora — bracket tournaments, built on top of the existing duels engine.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-multitenant-04.sql.
--
-- A teacher opens a tournament for one grade+level with a bracket size of
-- 4, 8 or 16. Students in that grade register while it's open. Once the
-- teacher starts it, the server randomly seeds a single-elimination
-- bracket: every pairing becomes a real row in the existing `duels` table
-- (tagged with tournament_id/round/slot), so matches are played through
-- the exact same live 1v1 duel screens and polling that already exist —
-- no new play mechanic, no simulated or local-only results. An uneven
-- head count gets a "bye" — a duel row with no opponent, auto-marked
-- done with that player as the winner, so the bracket stays a real,
-- persisted record either way. As soon as every match in a round is
-- done, submit_duel_score automatically seeds the next round server-side
-- (a tied match is broken by an impartial coin flip, same as any other
-- sudden-death decider, so the bracket always has exactly one winner per
-- match). When one player remains, the tournament is marked done and the
-- champion gets a coin bonus.
--
-- Safe on live data: only adds two new tables and three new nullable
-- columns on duels. Changes nothing existing. Safe to re-run.
-- ============================================================================

create table if not exists tournaments (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  teacher_id uuid references teachers(id) on delete set null,
  name text not null default '',
  grade int not null,
  level int not null,
  size int not null check (size in (4,8,16)),
  status text not null default 'reg' check (status in ('reg','active','done')),
  round int not null default 0,
  champion_id uuid references students(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table tournaments enable row level security;
revoke all on tournaments from anon, authenticated;

create table if not exists tournament_entries (
  tournament_id uuid not null references tournaments(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (tournament_id, student_id)
);
alter table tournament_entries enable row level security;
revoke all on tournament_entries from anon, authenticated;

alter table duels add column if not exists tournament_id uuid references tournaments(id) on delete cascade;
alter table duels add column if not exists round int;
alter table duels add column if not exists slot int;
create index if not exists duels_tournament_idx on duels(tournament_id, round);

-- Seeds one round's matches from an ordered list of player ids. Pairs
-- consecutively (so round 1 is pre-shuffled by the caller, and later
-- rounds simply keep winners paired by their bracket position); an odd
-- leftover gets a bye straight into the next round.
create or replace function _create_tournament_round(p_tournament_id uuid, p_round int, p_players uuid[])
returns void language plpgsql security definer as $$
declare
  t tournaments;
  n int := coalesce(array_length(p_players,1),0);
  i int := 1; slotn int := 0;
  p1 uuid; p2 uuid; p1name text; p2name text; v_code text;
begin
  select * into t from tournaments where tournaments.id = p_tournament_id;
  while i <= n loop
    p1 := p_players[i];
    select name into p1name from students where students.id = p1;
    if i+1 <= n then
      p2 := p_players[i+1];
      select name into p2name from students where students.id = p2;
      v_code := _gen_duel_code();
      insert into duels(code,grade,level,target,status,creator_id,creator_name,opponent_id,opponent_name,
                         school_id,tournament_id,round,slot)
        values(v_code, t.grade, t.level, 10, 'active', p1, p1name, p2, p2name,
               t.school_id, p_tournament_id, p_round, slotn);
    else
      v_code := _gen_duel_code();
      insert into duels(code,grade,level,target,status,creator_id,creator_name,winner_id,
                         school_id,tournament_id,round,slot)
        values(v_code, t.grade, t.level, 10, 'done', p1, p1name, p1,
               t.school_id, p_tournament_id, p_round, slotn);
    end if;
    slotn := slotn + 1;
    i := i + 2;
  end loop;
end; $$;

-- Called right after a duel is marked done. A no-op unless this duel
-- belongs to a tournament and that was the last unfinished match of its
-- round — in which case it seeds the next round, or finishes the
-- tournament if only a champion is left.
create or replace function _try_advance_tournament(p_tournament_id uuid)
returns void language plpgsql security definer as $$
declare
  t tournaments;
  v_unfinished int;
  v_winners uuid[];
begin
  if p_tournament_id is null then return; end if;
  select * into t from tournaments where tournaments.id = p_tournament_id;
  if not found or t.status <> 'active' then return; end if;

  select count(*) into v_unfinished from duels
    where duels.tournament_id = p_tournament_id and duels.round = t.round and duels.status <> 'done';
  if v_unfinished > 0 then return; end if;

  select array_agg(coalesce(d.winner_id,
           (array[d.creator_id, d.opponent_id])[1 + floor(random()*2)::int]) order by d.slot)
    into v_winners
  from duels d where d.tournament_id = p_tournament_id and d.round = t.round;

  if coalesce(array_length(v_winners,1),0) <= 1 then
    update tournaments set status='done', champion_id = v_winners[1] where tournaments.id = p_tournament_id;
    if v_winners[1] is not null then
      update students set coins = coins + 100 where students.id = v_winners[1];
      insert into coin_grants(student_id, teacher_id, amount, note)
        values (v_winners[1], t.teacher_id, 100, 'Tournament champion');
    end if;
  else
    update tournaments set round = t.round + 1 where tournaments.id = p_tournament_id;
    perform _create_tournament_round(p_tournament_id, t.round + 1, v_winners);
  end if;
end; $$;

-- ---------- teacher-facing: create, list, start ----------

create or replace function create_tournament(p_token text, p_name text, p_grade int, p_level int, p_size int)
returns table(id uuid) language plpgsql security definer as $$
declare me teachers; v_id uuid;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  if p_level is null or p_level < 0 or p_level > 2 then raise exception 'Unknown item'; end if;
  if p_size is null or p_size not in (4,8,16) then raise exception 'Unknown item'; end if;
  insert into tournaments(school_id, teacher_id, name, grade, level, size)
    values (me.school_id, me.id, left(trim(coalesce(p_name,'')),40), p_grade, p_level, p_size)
    returning tournaments.id into v_id;
  return query select v_id;
end; $$;

create or replace function list_tournaments_dashboard(p_token text)
returns table(id uuid, name text, grade int, level int, size int, status text, round int,
              champion_id uuid, champion_name text, entry_count int)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query
    select t.id, t.name, t.grade, t.level, t.size, t.status, t.round, t.champion_id, ch.name,
      (select count(*)::int from tournament_entries e where e.tournament_id = t.id)
    from tournaments t
    left join students ch on ch.id = t.champion_id
    where t.school_id = me.school_id
    order by t.created_at desc;
end; $$;

create or replace function start_tournament(p_token text, p_tournament_id uuid)
returns void language plpgsql security definer as $$
declare me teachers; t tournaments; v_players uuid[];
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  select * into t from tournaments where tournaments.id = p_tournament_id and tournaments.school_id = me.school_id;
  if not found then raise exception 'Unknown item'; end if;
  if t.status <> 'reg' then raise exception 'Already started'; end if;

  select array_agg(student_id order by random()) into v_players
    from tournament_entries where tournament_id = p_tournament_id;
  if coalesce(array_length(v_players,1),0) < 2 then
    raise exception 'Need at least 2 players to start';
  end if;

  update tournaments set status='active', round=1 where tournaments.id = p_tournament_id;
  perform _create_tournament_round(p_tournament_id, 1, v_players);
end; $$;

create or replace function cancel_tournament(p_token text, p_tournament_id uuid)
returns void language plpgsql security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  delete from tournaments where id = p_tournament_id and school_id = me.school_id and status = 'reg';
end; $$;

-- ---------- student-facing: see open tournaments, join, track the bracket ----------

create or replace function list_open_tournaments(p_token text)
returns table(id uuid, name text, grade int, level int, size int, entry_count int, joined boolean)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select t.id, t.name, t.grade, t.level, t.size,
      (select count(*)::int from tournament_entries e where e.tournament_id = t.id),
      exists(select 1 from tournament_entries e2 where e2.tournament_id = t.id and e2.student_id = s.id)
    from tournaments t
    where t.school_id = s.school_id and t.grade = s.grade and t.status = 'reg'
    order by t.created_at desc;
end; $$;

-- Tournaments I've already joined that are still in progress (registration
-- or an active bracket) — lets the client find its way back to a
-- tournament after a reload without relying on client-side memory.
create or replace function list_my_tournaments(p_token text)
returns table(id uuid, name text, grade int, level int, size int, status text)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select t.id, t.name, t.grade, t.level, t.size, t.status
    from tournaments t
    join tournament_entries e on e.tournament_id = t.id
    where e.student_id = s.id and t.status in ('reg','active')
    order by t.created_at desc;
end; $$;

create or replace function join_tournament(p_token text, p_tournament_id uuid)
returns void language plpgsql security definer as $$
declare s students; t tournaments; v_count int;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select * into t from tournaments where tournaments.id = p_tournament_id and tournaments.school_id = s.school_id;
  if not found or t.status <> 'reg' then raise exception 'Unknown item'; end if;
  if t.grade <> s.grade then raise exception 'Unknown item'; end if;
  select count(*) into v_count from tournament_entries where tournament_id = p_tournament_id;
  if v_count >= t.size then raise exception 'That bracket is already full'; end if;
  insert into tournament_entries(tournament_id, student_id) values (p_tournament_id, s.id)
    on conflict do nothing;
end; $$;

create or replace function leave_tournament(p_token text, p_tournament_id uuid)
returns void language plpgsql security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  delete from tournament_entries e using tournaments t
    where e.tournament_id = t.id and e.tournament_id = p_tournament_id
      and e.student_id = s.id and t.status = 'reg';
end; $$;

-- My status in one tournament I've joined: the tournament row, the full
-- bracket (every match so far, every round), and which match (if any) is
-- mine to play right now.
create or replace function my_tournament_status(p_token text, p_tournament_id uuid)
returns table(t_id uuid, t_name text, t_status text, t_round int, t_size int,
              champion_id uuid, champion_name text,
              match_id uuid, match_round int, match_slot int, match_status text,
              p1_id uuid, p1_name text, p1_score int, p2_id uuid, p2_name text, p2_score int,
              winner_id uuid, is_mine boolean)
language plpgsql stable security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select t.id, t.name, t.status, t.round, t.size, t.champion_id, ch.name,
      d.id, d.round, d.slot, d.status,
      d.creator_id, d.creator_name, d.creator_score,
      d.opponent_id, d.opponent_name, d.opponent_score,
      d.winner_id, (d.creator_id = s.id or d.opponent_id = s.id)
    from tournaments t
    left join students ch on ch.id = t.champion_id
    left join duels d on d.tournament_id = t.id
    where t.id = p_tournament_id and t.school_id = s.school_id
      and exists(select 1 from tournament_entries e where e.tournament_id = t.id and e.student_id = s.id)
    order by d.round, d.slot;
end; $$;

-- Replaces submit_duel_score so a finished tournament match auto-advances
-- the bracket, while keeping every bit of the original's behavior
-- (score updates, win detection, +20 coins for a plain duel win) intact.
create or replace function submit_duel_score(p_token text, p_id uuid, p_score int, p_done boolean)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language plpgsql security definer as $$
declare s students; v_row duels; v_score int; v_winner uuid;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select * into v_row from duels where duels.id = p_id;
  if not found then raise exception 'Unknown item'; end if;
  v_score := greatest(0, least(999, coalesce(p_score,0)));

  if v_row.creator_id = s.id then
    update duels set creator_score = v_score, creator_done = coalesce(p_done,false) where duels.id = p_id;
  elsif v_row.opponent_id = s.id then
    update duels set opponent_score = v_score, opponent_done = coalesce(p_done,false) where duels.id = p_id;
  else
    raise exception 'Not signed in';
  end if;

  select * into v_row from duels where duels.id = p_id;
  if v_row.status = 'active' and v_row.opponent_id is not null
     and (v_row.creator_done or v_row.opponent_done) then
    if v_row.creator_score > v_row.opponent_score then v_winner := v_row.creator_id;
    elsif v_row.opponent_score > v_row.creator_score then v_winner := v_row.opponent_id;
    else v_winner := null;
    end if;
    update duels set status = 'done', winner_id = v_winner where duels.id = p_id;
    if v_winner is not null and v_row.tournament_id is null then
      update students set coins = coins + 20 where students.id = v_winner;
      insert into coin_grants(student_id, teacher_id, amount, note)
        values (v_winner, null, 20, 'Duel win');
    end if;
    select * into v_row from duels where duels.id = p_id;
    if v_row.tournament_id is not null then
      perform _try_advance_tournament(v_row.tournament_id);
    end if;
  end if;

  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = p_id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
