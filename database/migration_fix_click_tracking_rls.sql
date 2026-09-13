-- =========================================================
-- Migration: Let logged-in staff log clicks too, not just anon visitors
-- =========================================================
-- DEPENDS ON: migration_add_business_table_rls.sql
--
-- Bug: `click` only had an INSERT policy for the `anon` role
-- (anon_insert_click, added when RLS was enabled on the business tables).
-- storefront/redirect.html inserts a click no matter who's browsing, but
-- if the browser also has an active staff session (e.g. testing a
-- campaign's "Test this link" button while logged into the dashboard),
-- supabase-js sends that request as `authenticated`, not `anon` -- and
-- there was no INSERT policy at all for `authenticated` on this table.
-- RLS silently rejected every one of those inserts, which is exactly why
-- clicks tested this way never showed up in Recent Clicks, the
-- country/device charts, or platform_performance's totals.
--
-- Fix: add a matching INSERT policy for active staff, so a click is
-- recorded regardless of whether the person clicking the link happens to
-- be logged into the dashboard in the same browser.
--
-- Run this once in the Supabase SQL Editor. For a brand-new project,
-- just run the full schema.sql instead -- it already includes this fix.
-- =========================================================

DROP POLICY IF EXISTS staff_insert_click ON click;
CREATE POLICY staff_insert_click ON click
    FOR INSERT TO authenticated
    WITH CHECK (current_staff_role() IS NOT NULL);
