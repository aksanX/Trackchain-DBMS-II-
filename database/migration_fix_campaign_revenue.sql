-- =========================================================
-- Run this once in the Supabase SQL Editor if your project already has
-- schema.sql (with the original campaign_performance/platform_performance
-- views) applied. For a brand-new project, just run the full schema.sql
-- instead -- it already includes this fix.
--
-- Bug: campaign_performance and platform_performance joined click and
-- order_item to tracking_link in the same query. A link with N clicks and
-- an attributed order fanned the order's line items out N times before
-- SUM(), so revenue was overcounted (e.g. 3 clicks + one $500 order showed
-- as $1,500). Click/order counts looked correct only because they used
-- COUNT(DISTINCT ...) to paper over the same fan-out.
--
-- Fix: pre-aggregate clicks and revenue per tracking_link in subqueries,
-- then join those already-deduplicated totals.
-- =========================================================

CREATE OR REPLACE VIEW campaign_performance AS
SELECT
    c.campaign_id,
    c.campaign_name,
    tl.platform,
    COALESCE(SUM(link_clicks.total_clicks), 0)::bigint AS total_clicks,
    COALESCE(SUM(link_orders.total_orders), 0)::bigint AS total_orders,
    COALESCE(SUM(link_orders.total_revenue), 0) AS total_revenue
FROM campaign c
LEFT JOIN tracking_link tl ON tl.campaign_id = c.campaign_id
LEFT JOIN (
    SELECT link_id, COUNT(*) AS total_clicks
    FROM click
    GROUP BY link_id
) link_clicks ON link_clicks.link_id = tl.link_id
LEFT JOIN (
    SELECT oa.link_id,
        COUNT(DISTINCT oa.order_id) AS total_orders,
           SUM(oi.quantity * oi.unit_price) AS total_revenue
    FROM order_attribution oa
    JOIN order_item oi ON oi.order_id = oa.order_id
    GROUP BY oa.link_id
) link_orders ON link_orders.link_id = tl.link_id
GROUP BY c.campaign_id, c.campaign_name, tl.platform
ORDER BY total_revenue DESC NULLS LAST;

CREATE OR REPLACE VIEW platform_performance AS
SELECT
    tl.platform,
    COALESCE(SUM(link_clicks.total_clicks), 0)::bigint AS total_clicks,
    COALESCE(SUM(link_orders.total_orders), 0)::bigint AS total_orders,
    COALESCE(SUM(link_orders.total_revenue), 0) AS total_revenue
FROM tracking_link tl
LEFT JOIN (
    SELECT link_id, COUNT(*) AS total_clicks
    FROM click
    GROUP BY link_id
) link_clicks ON link_clicks.link_id = tl.link_id
LEFT JOIN (
    SELECT oa.link_id,
        COUNT(DISTINCT oa.order_id) AS total_orders,
           SUM(oi.quantity * oi.unit_price) AS total_revenue
    FROM order_attribution oa
    JOIN order_item oi ON oi.order_id = oa.order_id
    GROUP BY oa.link_id
) link_orders ON link_orders.link_id = tl.link_id
GROUP BY tl.platform
ORDER BY total_revenue DESC NULLS LAST;

-- IMPORTANT: CREATE OR REPLACE VIEW resets security_invoker back to its
-- default (off) on any view it touches -- it does NOT preserve that
-- setting. If migration_secure_analytics_views.sql already ran on this
-- project, you MUST run it again after this file, or campaign_performance
-- and platform_performance will show up as security_definer_view again in
-- the Supabase linter even though the other 7 views are fine.
