-- =========================================================
-- Migration: Real staff authentication & admin-managed roles
-- =========================================================
-- Replaces the hardcoded username/password list that used to live in
-- frontend/js/role-guard.js with real Supabase Auth accounts. Staff no
-- longer self-select a role at login -- an admin creates their account
-- (via the in-app Staff Management page, backed by the
-- admin-manage-staff edge function) and assigns the role at that point.
--
-- This table is NEW and holds account/role data, which is why it gets
-- RLS -- unlike the 17 pre-existing business tables in schema.sql
-- Section 11, which stay open on purpose for this course project (see
-- the comment there). Who is allowed to log in as which role is not
-- something we want world-readable/writable through the anon key.

CREATE TABLE IF NOT EXISTS public.staff_profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       TEXT NOT NULL,
    full_name   TEXT NOT NULL,
    role        TEXT NOT NULL CHECK (role IN ('admin', 'purchasing', 'marketing', 'warehouse', 'shipment')),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_by  UUID REFERENCES auth.users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Lets a logged-in user (and RLS policies) find their own role without
-- re-querying staff_profiles directly -- SECURITY DEFINER so it can read
-- the table even though the row-level policies below would otherwise
-- only let a user see their own row.
CREATE OR REPLACE FUNCTION public.current_staff_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT role FROM staff_profiles
    WHERE id = auth.uid() AND is_active = TRUE
    LIMIT 1;
$$;

ALTER TABLE public.staff_profiles ENABLE ROW LEVEL SECURITY;

-- Everyone can read their own row (so the frontend can resolve "who am I").
DROP POLICY IF EXISTS staff_read_own ON public.staff_profiles;
CREATE POLICY staff_read_own ON public.staff_profiles
    FOR SELECT
    USING (id = auth.uid());

-- Admins can read every row (Staff Management page listing).
DROP POLICY IF EXISTS staff_read_all_if_admin ON public.staff_profiles;
CREATE POLICY staff_read_all_if_admin ON public.staff_profiles
    FOR SELECT
    USING (public.current_staff_role() = 'admin');

-- No INSERT/UPDATE/DELETE policies on purpose: those only ever happen
-- through the admin-manage-staff edge function, which uses the service
-- role key (bypasses RLS entirely) after verifying the caller is an
-- active admin. The anon/authenticated client can never write this
-- table directly, even if it belongs to an admin's browser session.

-- =========================================================
-- Bootstrap the first admin (run manually, once)
-- =========================================================
-- 1. Supabase Dashboard -> Authentication -> Users -> Add User.
--    Create yourself with a real email + password, "Auto Confirm User" on.
-- 2. Copy that user's UUID from the Users table, then run:
--
--    INSERT INTO public.staff_profiles (id, email, full_name, role, is_active)
--    VALUES ('<paste-the-uuid-here>', '<same-email>', '<your-name>', 'admin', TRUE);
--
-- Every other staff account from here on is created through the app's
-- Staff Management page (admin-only), never manually.
