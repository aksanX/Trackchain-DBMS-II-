-- =========================================================
-- Migration: Make analytics views respect the caller's RLS policies
-- =========================================================
-- DEPENDS ON: migration_add_business_table_rls.sql
--
-- PostgreSQL views created by the default project owner are security
-- definer by default. That means a caller can read the view using the
-- owner's access, which bypasses the row-level security policies on the
-- underlying business tables. Supabase flags this as
-- "security_definer_view".
--
-- `security_invoker = true` makes each view use the querying user's table
-- privileges and RLS policies instead. All internal pages that use these
-- views already require an active staff account, so their normal queries
-- continue to work; anonymous storefront pages do not use these views.
--
-- Run this once in the Supabase SQL Editor AFTER the schema, functional
-- migrations, staff-auth migration, and business-table RLS migration.
-- =========================================================

ALTER VIEW public.warehouse_capacity    SET (security_invoker = true);
ALTER VIEW public.campaign_performance  SET (security_invoker = true);
ALTER VIEW public.platform_performance  SET (security_invoker = true);
ALTER VIEW public.supplier_product_count SET (security_invoker = true);
ALTER VIEW public.purchase_history       SET (security_invoker = true);
ALTER VIEW public.warehouse_stock_age    SET (security_invoker = true);
ALTER VIEW public.warehouse_rent         SET (security_invoker = true);
ALTER VIEW public.warehouse_overview     SET (security_invoker = true);
ALTER VIEW public.order_fulfilment       SET (security_invoker = true);

-- Verification (run separately after the statements above):
-- SELECT c.relname, c.reloptions
-- FROM pg_class c
-- WHERE c.relnamespace = 'public'::regnamespace
--   AND c.relname IN (
--     'warehouse_capacity', 'campaign_performance', 'platform_performance',
--     'supplier_product_count', 'purchase_history', 'warehouse_stock_age',
--     'warehouse_rent', 'warehouse_overview', 'order_fulfilment'
--   )
-- ORDER BY c.relname;
