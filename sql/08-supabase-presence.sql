-- ============================================================================
-- Mathalora — shared live island presence.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-avatar-basics.sql.
--
-- Lets students see each other moving around the Explore map in real time,
-- the same way the live duels work: no websocket/Realtime channel, just a
-- small presence table that each client upserts into every ~1.3s (its own
-- x/y) and reads from (everyone else's recent x/y) on the same cadence.
-- A row older than 8 seconds is treated as "gone" (tab closed, idle, etc.)
-- and filtered out server-side, so nobody has to explicitly clean up.
--
-- Safe on live data: only adds a new table and new functions. Changes
-- nothing existing. Safe to re-run.
-- ============================================================================

create table if not exists presence (
  student_id uuid primary key references students(id) on delete cascade,
  x numeric not null default 50,
  y numeric not null default 50,
  updated_at timestamptz not null default now()
);
alter table presence enable row level security;
revoke all on presence from anon, authenticated;

-- Upserts the caller's own position, then returns everyone else's recent
-- position (plus the bits of their profile needed to draw them: name,
-- avatar, layers, frame) so the client can render them without a 2nd call.
create or replace function update_presence(p_token text, p_x numeric, p_y numeric)
returns table(id uuid, name text, avatar text, avatar_layers jsonb, frame text, x numeric, y numeric)
language plpgsql security definer as $$
declare s students; v_x numeric; v_y numeric;
begin
  s := _student_from_session(p_token);
  if s.id is null then raise exception 'Not signed in'; end if;
  v_x := greatest(0, least(100, coalesce(p_x,50)));
  v_y := greatest(0, least(100, coalesce(p_y,50)));

  insert into presence (student_id, x, y, updated_at)
    values (s.id, v_x, v_y, now())
    on conflict (student_id) do update set x = v_x, y = v_y, updated_at = now();

  return query
    select st.id, st.name, st.avatar, st.avatar_layers, st.frame, p.x, p.y
    from presence p
    join students st on st.id = p.student_id
    where p.student_id <> s.id and p.updated_at > now() - interval '8 seconds'
    order by p.updated_at desc
    limit 60;
end; $$;

-- Called when a student leaves the Explore map (or logs out), so they
-- disappear for others right away instead of waiting out the 8s window.
create or replace function clear_presence(p_token text)
returns void language plpgsql security definer as $$
declare s students;
begin
  s := _student_from_session(p_token);
  if s.id is null then return; end if;
  delete from presence where student_id = s.id;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
