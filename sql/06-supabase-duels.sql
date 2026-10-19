-- ============================================================================
-- Mathalora — live 1v1 duels.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-island-freeform.sql.
--
-- Lets two students race on the same level: one creates a duel and gets a
-- short code, the other joins with that code, and both race to answer
-- p_target questions correctly first. The client polls for the opponent's
-- live score every ~1.3s (no websocket/Realtime channel needed) and also
-- gets the opponent's latest score for free every time it submits its own.
--
-- Safe on live data: only adds a new table and new functions. Changes
-- nothing existing. Safe to re-run.
-- ============================================================================

create table if not exists duels (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  grade int not null,
  level int not null,
  target int not null default 10,
  status text not null default 'waiting' check (status in ('waiting','active','done')),
  creator_id uuid references students(id) on delete cascade,
  creator_name text not null,
  creator_score int not null default 0,
  creator_done boolean not null default false,
  opponent_id uuid references students(id) on delete cascade,
  opponent_name text,
  opponent_score int not null default 0,
  opponent_done boolean not null default false,
  winner_id uuid,
  created_at timestamptz not null default now()
);
alter table duels enable row level security;
revoke all on duels from anon, authenticated;

create or replace function _gen_duel_code()
returns text language plpgsql as $$
declare v_code text;
begin
  loop
    v_code := upper(substr(encode(gen_random_bytes(4),'hex'),1,5));
    if not exists(select 1 from duels where duels.code = v_code) then return v_code; end if;
  end loop;
end; $$;

create or replace function create_duel(p_token text, p_level int, p_target int default 10)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language plpgsql security definer as $$
declare s students; v_id uuid; v_code text; v_target int := greatest(3, least(20, coalesce(p_target,10)));
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  if p_level is null or p_level < 0 or p_level > 2 then raise exception 'Unknown item'; end if;
  v_code := _gen_duel_code();
  insert into duels (code, grade, level, target, creator_id, creator_name)
    values (v_code, s.grade, p_level, v_target, s.id, s.name)
    returning duels.id into v_id;
  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = v_id;
end; $$;

create or replace function join_duel(p_token text, p_code text)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language plpgsql security definer as $$
declare s students; v_row duels;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  select * into v_row from duels where duels.code = upper(trim(p_code));
  if not found then raise exception 'Invalid code'; end if;
  if v_row.creator_id = s.id then raise exception 'Invalid code'; end if;
  if v_row.status = 'waiting' then
    update duels set opponent_id = s.id, opponent_name = s.name, status = 'active'
      where duels.id = v_row.id;
  elsif v_row.opponent_id is not null and v_row.opponent_id <> s.id then
    raise exception 'Invalid code';
  end if;
  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = v_row.id;
end; $$;

create or replace function get_duel(p_id uuid)
returns table(id uuid, code text, grade int, level int, target int, status text,
              creator_id uuid, creator_name text, creator_score int, creator_done boolean,
              opponent_id uuid, opponent_name text, opponent_score int, opponent_done boolean,
              winner_id uuid)
language sql stable security definer as $$
  select id, code, grade, level, target, status, creator_id, creator_name, creator_score, creator_done,
    opponent_id, opponent_name, opponent_score, opponent_done, winner_id from duels where id = p_id;
$$;

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
    if v_winner is not null then
      update students set coins = coins + 20 where students.id = v_winner;
      insert into coin_grants(student_id, teacher_id, amount, note)
        values (v_winner, null, 20, 'Duel win');
    end if;
  end if;

  return query select d.id, d.code, d.grade, d.level, d.target, d.status, d.creator_id, d.creator_name,
    d.creator_score, d.creator_done, d.opponent_id, d.opponent_name, d.opponent_score, d.opponent_done,
    d.winner_id from duels d where d.id = p_id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
