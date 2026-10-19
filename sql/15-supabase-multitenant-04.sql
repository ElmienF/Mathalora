-- ============================================================================
-- Mathalora — multi-tenant platform, part 4: platform-admin account bootstrap
-- + a small admin-management RPC surface. Run this ONCE in the Supabase SQL
-- Editor, AFTER supabase-multitenant-03.sql.
--
-- Parts 1-3 built the full platform_admins table and the login/session/
-- list_schools/add_school functions, but left one gap: there was never a
-- way to CREATE the first platform admin account. The table starts empty
-- and stays empty forever, because platform_admin_login() can only check
-- passwords against rows that already exist and nothing could ever insert
-- the first one. This file closes that gap and adds the couple of small
-- RPCs the new admin-facing client screens need:
--
--   1. platform_admin_bootstrap_needed() — PUBLIC. Tells the client whether
--      any platform admin exists yet, so the "sign in" screen can offer a
--      one-time "create the first admin account" form instead when the
--      table is empty, and never again once it isn't.
--   2. bootstrap_platform_admin(p_name, p_password) — PUBLIC, but only ever
--      succeeds once: it raises an exception if ANY platform_admins row
--      already exists. This is the one deliberate "no auth required" RPC
--      in the whole admin surface, and it is safe specifically because it
--      is self-disabling the instant it has been used a single time.
--   3. add_platform_admin(p_token, p_name, p_password) — requires an
--      existing admin session. Lets a signed-in admin invite a co-admin
--      without needing direct database access.
--   4. list_platform_admins(p_token) — requires an existing admin session.
--      Shows who else has admin access, for the admin-management screen.
--   5. platform_admin_logout(p_token) — same shape as teacher_logout /
--      student_logout, for symmetry.
--
-- Nothing here touches schools, teachers or students. Safe to re-run.
-- ============================================================================

create or replace function platform_admin_bootstrap_needed()
returns boolean language sql stable security definer as $$
  select not exists (select 1 from platform_admins);
$$;

create or replace function bootstrap_platform_admin(p_name text, p_password text)
returns table(session_token text, id uuid, name text)
language plpgsql security definer as $$
declare v_token text; v_id uuid;
begin
  if exists (select 1 from platform_admins) then
    raise exception 'A platform admin account already exists — sign in instead.';
  end if;
  if length(trim(p_name)) < 1 then raise exception 'Name is required'; end if;
  if length(p_password) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  v_token := _new_token();
  insert into platform_admins(name, password_hash, session_token, session_expires)
  values (left(trim(p_name),60), crypt(p_password, gen_salt('bf')), v_token, now() + interval '30 days')
  returning platform_admins.id into v_id;
  return query select v_token, pa.id, pa.name from platform_admins pa where pa.id = v_id;
end; $$;

create or replace function add_platform_admin(p_token text, p_name text, p_password text)
returns table(id uuid, name text)
language plpgsql security definer as $$
declare v_id uuid;
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  if length(trim(p_name)) < 1 then raise exception 'Name is required'; end if;
  if length(p_password) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  if exists (select 1 from platform_admins where lower(platform_admins.name) = lower(trim(p_name))) then
    raise exception 'An admin with that name already exists';
  end if;
  insert into platform_admins(name, password_hash) values (left(trim(p_name),60), crypt(p_password, gen_salt('bf')))
  returning platform_admins.id into v_id;
  return query select pa.id, pa.name from platform_admins pa where pa.id = v_id;
end; $$;

create or replace function list_platform_admins(p_token text)
returns table(id uuid, name text, created_at timestamptz)
language plpgsql stable security definer as $$
begin
  if (_platform_admin_from_session(p_token)).id is null then raise exception 'Not signed in'; end if;
  return query select pa.id, pa.name, pa.created_at from platform_admins pa order by pa.created_at;
end; $$;

create or replace function platform_admin_logout(p_token text)
returns void language plpgsql security definer as $$
begin
  update platform_admins set session_token = null, session_expires = null where session_token = p_token;
end; $$;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
