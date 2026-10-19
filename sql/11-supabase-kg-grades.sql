-- ============================================================================
-- Mathalora — add KG1 and KG2 grades.
-- Run this ONCE in the Supabase SQL Editor, AFTER supabase-big-builds.sql.
--
-- KG1 and KG2 are stored as grade -1 and grade 0 (students.grade already
-- allows any integer, no change needed there). The only thing that blocked
-- them was the sections table's check constraint, which only allowed 1-12
-- — this widens it to -1-12 so a class can be created for KG1/KG2 too.
--
-- Safe on live data: only widens a check constraint. Changes nothing else.
-- Safe to re-run.
-- ============================================================================

alter table sections drop constraint if exists sections_grade_check;
alter table sections add constraint sections_grade_check check (grade between -1 and 12);
