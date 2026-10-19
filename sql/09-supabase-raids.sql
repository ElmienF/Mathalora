-- ============================================================================
-- Mathalora — island raids (asynchronous math "fights").
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-presence.sql.
--
-- A student picks a target from their grade on the "Islands" screen and
-- plays a short solo math challenge to raid them — the defender does NOT
-- need to be online. A win steals a slice of the defender's coins and
-- wrecks one of their placed buildings (which the defender then repairs
-- with coins on their own Build tab). A loss costs the attacker nothing.
-- There's a 10-minute cooldown per attacker+defender pair so nobody can
-- be raided over and over back to back.
--
-- Safe on live data: only adds a new table and new functions, and widens
-- what's stored in a building's jsonb entry (adds an optional "wrecked"
-- flag the client already knows how to ignore if absent). Changes
-- nothing existing. Safe to re-run.
-- ============================================================================

create table if not exists raids (
  id uuid primary key default gen_random_uuid(),
  attacker_id uuid references students(id) on delete cascade,
  defender_id uuid references students(id) on delete cascade,
  success boolean not null,
  coins_stolen int not null default 0,
  wrecked_key text,
  created_at timestamptz not null default now()
);
alter table raids enable row level security;
revoke all on raids from anon, authenticated;
create index if not exists raids_cooldown_idx on raids(attacker_id, defender_id, created_at desc);

-- Other same-grade students you could raid, with a building count and
-- how many seconds are left on your cooldown against each one (0 = free).
create or replace function list_raid_targets(p_token text)
returns table(id uuid, name text, avatar text, avatar_layers jsonb, frame text,
              coins int, building_count int, cooldown_seconds int)
language plpgsql security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  return query
    select st.id, st.name, st.avatar, st.avatar_layers, st.frame, st.coins,
      (select count(*)::int from jsonb_each(coalesce(st.island,'{}'::jsonb))),
      greatest(0, 600 - floor(extract(epoch from (now() -
        (select max(r.created_at) from raids r where r.attacker_id = s.id and r.defender_id = st.id and r.success)
      )))::int)
    from students st
    where st.id <> s.id and st.guest = false and st.grade = s.grade
    order by st.name;
end; $$;

-- Resolves one raid attempt. p_won is the client's report of whether the
-- attacker beat the challenge (same trust model as the rest of the app's
-- client-reported scores). Re-checks the cooldown server-side so it can't
-- be bypassed by calling this repeatedly.
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
    update students set coins = students.coins + v_stolen where students.id = s.id;
  end if;

  insert into raids (attacker_id, defender_id, success, coins_stolen, wrecked_key)
    values (s.id, p_defender_id, coalesce(p_won,false), v_stolen, v_key);

  return query select st.coins, v_stolen, v_wrecked, d.name from students st where st.id = s.id;
end; $$;

-- Repairs one wrecked building on your own island.
create or replace function repair_building(p_token text, p_key text)
returns table(coins int, island jsonb)
language plpgsql security definer as $$
declare s students; v_entry jsonb; v_item text; v_price int; v_cost int;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  v_entry := s.island->p_key;
  if v_entry is null then raise exception 'Unknown item'; end if;
  if not coalesce((v_entry->>'wrecked')::boolean, false) then
    update students set island = jsonb_set(s.island, array[p_key], v_entry - 'wrecked') where students.id = s.id;
    return query select st.coins, st.island from students st where st.id = s.id;
    return;
  end if;
  v_item := v_entry->>'id';
  select price into v_price from catalog_items where catalog_items.id = v_item;
  v_cost := greatest(5, floor(coalesce(v_price,10) / 2.0)::int);
  if s.coins < v_cost then raise exception 'Not enough coins'; end if;

  update students set
    coins = students.coins - v_cost,
    island = jsonb_set(s.island, array[p_key], v_entry - 'wrecked')
  where students.id = s.id;

  return query select st.coins, st.island from students st where st.id = s.id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
