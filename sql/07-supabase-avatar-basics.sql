-- ============================================================================
-- Mathalora — free starter hair & outfit options.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-bloom-island-v2.sql.
--
-- Adds a small set of FREE (price 0) hair and outfit items. New students
-- pick one of each for free during sign-up (before setting a password);
-- everything else in the Shop (fancier hair/outfits, accessories, frames,
-- avatars) still costs coins, unlocked afterward.
--
-- The existing equip_layer() function already handles price-0 items with
-- no changes needed — it only charges coins when price > the student's
-- free allowance, i.e. never, for these.
--
-- Safe on live data: only inserts new catalog rows (ON CONFLICT DO NOTHING).
-- Safe to re-run.
-- ============================================================================

insert into catalog_items (id, kind, name, value, price, sort) values
  -- free starter hair (sort 0.x so they list first within "hair")
  ('h_basic_short',  'hair', 'Short Hair',   '🙂', 0, -4),
  ('h_basic_curly',  'hair', 'Curly Hair',   '😄', 0, -3),
  ('h_basic_pony',   'hair', 'Ponytail',     '😺', 0, -2),
  ('h_basic_buzz',   'hair', 'Buzz Cut',     '🧑', 0, -1),
  -- free starter outfits
  ('o_basic_tshirt', 'outfit', 'T-Shirt',    '👚', 0, -4),
  ('o_basic_hoodie', 'outfit', 'Hoodie',     '🧶', 0, -3),
  ('o_basic_dress',  'outfit', 'Sundress',   '👗', 0, -2),
  ('o_basic_shorts', 'outfit', 'Shorts Set', '🩳', 0, -1)
on conflict (id) do nothing;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
