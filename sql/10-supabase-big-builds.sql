-- ============================================================================
-- Mathalora — bigger premium build items (houses, cars, and more).
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-raids.sql.
--
-- Adds a tier of pricier decorations on top of the existing building
-- catalog (pine tree, cottage, castle, etc.) for students who've saved up
-- a bigger pile of coins. They place/move/remove exactly like the existing
-- buildings do — the free-form build system doesn't need any changes.
--
-- Safe on live data: only inserts new catalog rows (ON CONFLICT DO
-- NOTHING). Safe to re-run.
-- ============================================================================

insert into catalog_items (id, kind, name, value, price, sort) values
  ('b_treehouse',  'building', 'Treehouse',       '🏠', 220, 15),
  ('b_car',        'building', 'Sports Car',      '🚗', 240, 16),
  ('b_towntruck',  'building', 'Monster Truck',   '🛻', 260, 17),
  ('b_pool',       'building', 'Swimming Pool',   '🏊', 280, 18),
  ('b_statue',     'building', 'Giant Statue',    '🗽', 300, 19),
  ('b_lighthouse', 'building', 'Lighthouse',      '🗼', 320, 20),
  ('b_rollercoaster','building','Roller Coaster', '🎢', 350, 21),
  ('b_stadium',    'building', 'Stadium',         '🏟️', 380, 22),
  ('b_mansion',    'building', 'Mansion',         '🏛️', 420, 23),
  ('b_rocket',     'building', 'Rocket Pad',      '🚀', 460, 24)
on conflict (id) do nothing;

grant execute on all functions in schema public to anon, authenticated;
notify pgrst, 'reload schema';
