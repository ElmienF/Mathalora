-- ============================================================================
-- Mathalora — separate behaviour coins from format/competition coins.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-team-quests.sql.
--
-- Today every coin a student has lives in one balance (students.coins),
-- whether it came from a teacher's ClassDojo-style "good behaviour" grant
-- (grant_coins) or from actually doing maths (solo play, duels, tournaments,
-- team quests, raids). The spec is explicit: "Behaviour coins remain
-- separate from competition scores." Two things already satisfy half of
-- that on their own — every leaderboard, competition, tournament and
-- festival ranks students by `points`, and `points` is only ever moved by
-- real quiz performance (student_save_progress) — grant_coins has never
-- touched it. So rankings were never distorted by behaviour grants.
--
-- What was missing is visible, trustworthy TRACKING: there was no way for
-- a teacher or student to see how much of a coin balance came from being
-- kind/on-task versus from actually mastering maths. This migration adds
-- two lifetime running totals that only ever go up, so that distinction is
-- never lost even as coins get spent in the shop or stolen in a raid:
--
--   students.behavior_coins_total  — lifetime coins from grant_coins only
--   students.format_coins_total    — lifetime coins from every maths-play
--                                     format: Solo Adventure, Friendly Duel,
--                                     Grade Tournament, Team Quest, and
--                                     raid steals (which only ever move
--                                     already-earned format coins between
--                                     students, so they're tagged the same
--                                     way on the winning side)
--
-- The single spendable `coins` balance itself is UNCHANGED — this is purely
-- additive bookkeeping, so the shop, equip screens and every existing coin
-- amount keep working exactly as they did. Safe on live data: it only adds
-- columns (defaulted to 0, then backfilled below) and replaces functions.
-- Safe to re-run.
-- ============================================================================

alter table students add column if not exists behavior_coins_total int not null default 0;
alter table students add column if not exists format_coins_total int not null default 0;

-- ---------- one-time backfill from history, best-effort ----------
-- grant_coins is the only source that ever writes a free-text note into
-- coin_grants with teacher_id set to the granting teacher's own id *and*
-- a note the teacher chose themselves; every automatic award instead uses
-- one of three fixed, reserved note strings. That tells the two apart
-- reliably for everything logged so far.
update students s set behavior_coins_total = coalesce((
  select sum(g.amount) from coin_grants g
  where g.student_id = s.id
    and coalesce(g.note,'') not in ('Duel win','Tournament champion','Team Quest goal reached')
), 0)
where behavior_coins_total = 0;

-- Raids never wrote to coin_grants, so fold historical successful steals
-- into the attacker's format total directly from the raids table.
update students s set format_coins_total =
  greatest(0, s.coins - s.behavior_coins_total)
  + coalesce((select sum(r.coins_stolen) from raids r where r.attacker_id = s.id and r.success), 0)
where format_coins_total = 0;

-- ---------- behaviour coins: only grant_coins ever adds to this total ----------
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

  update students set coins = coins + p_amount, behavior_coins_total = behavior_coins_total + p_amount
    where id = p_student_id and school_id = me.school_id
    returning coins into v_coins;
  if v_coins is null then raise exception 'Unknown student'; end if;

  insert into coin_grants(student_id, teacher_id, amount, note)
    values (p_student_id, me.id, p_amount, left(coalesce(p_note, ''), 60));

  return v_coins;
end; $$;

-- ---------- format coins: every maths-play award bumps this total too ----------

-- Solo Adventure (and every island's own save) — the everyday fluency loop.
create or replace function student_save_progress(p_token text, p_points_delta int,
  p_progress_patch jsonb, p_blitz_patch jsonb, p_last_grade int, p_coins_delta int default 0)
returns table(points int, progress jsonb, blitz jsonb, coins int)
language plpgsql security definer as $$
declare v_coins_delta int := greatest(0, least(500, coalesce(p_coins_delta, 0)));
begin
  update students set
    points = students.points + coalesce(p_points_delta,0),
    progress = students.progress || coalesce(p_progress_patch,'{}'::jsonb),
    blitz = students.blitz || coalesce(p_blitz_patch,'{}'::jsonb),
    last_grade = coalesce(p_last_grade, last_grade),
    coins = students.coins + v_coins_delta,
    format_coins_total = students.format_coins_total + v_coins_delta,
    session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.points, s.progress, s.blitz, s.coins from students s where s.session_token = p_token;
end; $$;

-- Friendly Duel + Grade Tournament (bracket-aware submit_duel_score).
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
      update students set coins = coins + 20, format_coins_total = format_coins_total + 20 where students.id = v_winner;
      insert into coin_grants(student_id, teacher_id, amount, note)
        values (v_winner, null, 20, 'Duel win');
    end if;
    select * into v_row from duels where duels.id = p_id;
    if v_row.tournament_id is not null then
      perform _try_advance_tournament(v_row.tournament_id);
      select * into v_row from duels where duels.id = p_id;
    end if;
  end if;

  return query select v_row.id, v_row.code, v_row.grade, v_row.level, v_row.target, v_row.status,
    v_row.creator_id, (select name from students where students.id = v_row.creator_id),
    v_row.creator_score, v_row.creator_done,
    v_row.opponent_id, (select name from students where students.id = v_row.opponent_id),
    v_row.opponent_score, v_row.opponent_done, v_row.winner_id;
end; $$;

-- Grade Tournament champion bonus.
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
      update students set coins = coins + 100, format_coins_total = format_coins_total + 100 where students.id = v_winners[1];
      insert into coin_grants(student_id, teacher_id, amount, note)
        values (v_winners[1], t.teacher_id, 100, 'Tournament champion');
    end if;
  else
    update tournaments set round = t.round + 1 where tournaments.id = p_tournament_id;
    perform _create_tournament_round(p_tournament_id, t.round + 1, v_winners);
  end if;
end; $$;

-- Team Quest shared-goal bonus.
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
      update students set coins = coins + 25, format_coins_total = format_coins_total + 25
        where id in (select student_id from team_quest_members where team_id = r.team_id);
      insert into coin_grants(student_id, teacher_id, amount, note)
        select student_id, null, 25, 'Team Quest goal reached'
        from team_quest_members where team_id = r.team_id;
    end if;
  end loop;
end; $$;

-- Raid steal — a transfer of already-earned format coins, tagged as a
-- format earning for the winner only (the loser's totals aren't touched;
-- they're lifetime-earned counters, not a record of current holdings).
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
    update students set coins = students.coins + v_stolen, format_coins_total = students.format_coins_total + v_stolen
      where students.id = s.id;
  end if;

  insert into raids (attacker_id, defender_id, success, coins_stolen, wrecked_key)
    values (s.id, p_defender_id, coalesce(p_won,false), v_stolen, v_key);

  return query select st.coins, v_stolen, v_wrecked, d.name from students st where st.id = s.id;
end; $$;

-- ---------- expose both totals to the student's own session and to the teacher dashboard ----------
drop function if exists student_session(text);
create or replace function student_session(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, avatar text,
              points int, progress jsonb, blitz jsonb, last_grade int, guest boolean,
              coins int, island jsonb, owned_items jsonb, frame text, avatar_layers jsonb,
              behavior_coins_total int, format_coins_total int)
language plpgsql security definer as $$
begin
  update students set session_expires = now() + interval '30 days'
  where session_token = p_token and session_expires > now();
  return query select s.id, s.name, s.grade, s.section_id, sec.name, s.avatar, s.points,
    s.progress, s.blitz, s.last_grade, s.guest, s.coins, s.island, s.owned_items, s.frame, s.avatar_layers,
    s.behavior_coins_total, s.format_coins_total
  from students s left join sections sec on sec.id = s.section_id
  where s.session_token = p_token and s.session_expires > now();
end; $$;

drop function if exists list_students(text);
create or replace function list_students(p_token text)
returns table(id uuid, name text, grade int, section_id uuid, section_name text, has_password boolean,
              coins int, progress jsonb, behavior_coins_total int, format_coins_total int)
language plpgsql stable security definer as $$
declare me teachers;
begin
  me := _teacher_from_session(p_token);
  if me.id is null then raise exception 'Not signed in'; end if;
  return query select s.id, s.name, s.grade, s.section_id, sec.name, (s.password_hash is not null),
    s.coins, coalesce(s.progress, '{}'::jsonb), s.behavior_coins_total, s.format_coins_total
    from students s left join sections sec on sec.id = s.section_id
    where s.guest = false and s.school_id = me.school_id order by s.grade nulls first, s.name;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
