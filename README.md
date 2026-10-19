# Mathalora

**Master maths. Build your world.**

A multi-tenant, island-adventure math practice platform for UAE K-12 schools.
Students progress through 7 competition formats and 10 curriculum islands,
earn coins, customize an avatar and vehicle, and compete in duels,
tournaments, team quests and school festivals. Teachers and platform admins
get a full management dashboard. Backed by Supabase (Postgres + PostgREST
RPC functions) with fully custom, opaque-token sessions — no Supabase Auth.

## Structure

- `bloom-mental-math-mastery-challenge.html` — the entire client app: a
  single self-contained HTML/CSS/JS file (no build step, no bundler). Open
  it directly in a browser, or host it as a static file anywhere.
- `sql/` — Supabase/Postgres migrations, numbered in required run order
  (`01-...` through `22-...`). Every file is idempotent — safe to re-run.

## Deploying

1. Create a Supabase project.
2. Run every file in `sql/` through the Supabase SQL Editor **in numeric
   order** (01 first, 22 last).
3. In the HTML file, confirm the Supabase URL and anon key near the top of
   the `<script>` block point at your project.
4. Host the HTML file anywhere that serves static files (it's a single
   file — any static host, S3 bucket, Netlify, Vercel, GitHub Pages, your
   own server, etc. all work).
5. Bootstrap the first platform admin: the app guides you through this on
   first load when no platform admin exists yet.

## Testing

The project is tested end-to-end against a real local Postgres instance
(for the SQL/RPC layer) and against hand-maintained mock Supabase clients
driven through Playwright (for the client). There's no bundled test
runner config yet — tests currently live outside this repo as standalone
Playwright scripts; see commit history / project notes for the current
suite. Contributions should add a Playwright script alongside any new
feature and confirm existing suites still pass before merging.

## Conventions

- No Supabase Auth — all sessions are custom opaque tokens minted and
  checked inside `SECURITY DEFINER` Postgres functions, with RLS and
  revoked direct table privileges locking down everything else.
- All interactive surfaces (level maps, menus, buttons) are real DOM
  controls — never a flattened screenshot standing in for a UI.
- Simulated/local-only state is never presented as a production feature
  (e.g. multiplayer presence is real, not faked).
