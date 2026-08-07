-- =========================================================
-- TrackChain — Recording stock transfers between hubs
-- =========================================================
-- Run this once in the Supabase SQL Editor, AFTER
-- migration_add_warehouse_capacity_rent.sql. For a brand-new project just run
-- schema.sql -- it already contains everything below.
--
-- THE PROBLEM THIS FIXES
--
-- Moving stock between hubs was two UPDATEs against `inventory` fired from the
-- browser, and nothing else. That left two holes:
--
--   1. NO RECORD. Once the two updates landed, the database looked exactly as
--      if the units had always been in their new hub. You could not ask what
--      moved, when, or which way. (audit_log caught two 'inventory / UPDATE'
--      rows, but it stores no before/after values, so they say nothing about
--      product, quantity or direction -- and nothing ties the two rows into
--      one move.)
--
--   2. AGE RESET TO ZERO. warehouse_stock_age reconstructs how long stock has
--      been sitting from arrival dates, and a transfer created no arrival
--      record at the destination. Moved units therefore dropped out of the
--      aging calculation entirely and were billed at the flat 1.0x rate
--      forever -- so a hub could clear a 3x dead-stock surcharge simply by
--      bouncing the pallet to the next hub.
--
-- Both come from the same root cause: purchases had provenance (purchase +
-- purchase_item, carrying a date), transfers had none. This migration gives
-- transfers the same provenance, and moves them through one function so the
-- two inventory writes finally share a transaction.
-- =========================================================


-- ---------------------------------------------------------
-- 1. The record itself.
-- ---------------------------------------------------------
-- origin_date is the interesting column. transfer_date is when the move
-- happened; origin_date is the receipt date the moved units CARRY WITH THEM.
-- transfer_stock_api() below splits each move along the source's FIFO lots and
-- writes one row per lot with that lot's own date, so a 90-day-old unit is
-- still 90 days old after it lands.
--
-- Rows here do NOT move stock on their own; they record a move that
-- transfer_stock_api() also applies to `inventory`. Insert through that
-- function, never by hand.

CREATE TABLE IF NOT EXISTS stock_transfer (
    transfer_id       SERIAL PRIMARY KEY,
    from_warehouse_id INT NOT NULL REFERENCES warehouse(warehouse_id),
    to_warehouse_id   INT NOT NULL REFERENCES warehouse(warehouse_id),
    product_id        INT NOT NULL REFERENCES product(product_id),
    quantity          INT NOT NULL CHECK (quantity > 0),
    transfer_date     TIMESTAMP NOT NULL DEFAULT NOW(),
    origin_date       TIMESTAMP NOT NULL DEFAULT NOW(),
    CHECK (from_warehouse_id <> to_warehouse_id)
);

ALTER TABLE stock_transfer DISABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------
-- 2. Teach the aging view about the second way stock arrives.
-- ---------------------------------------------------------
-- Units arrive by one of exactly two routes -- a purchase or a transfer in --
-- so `all_lots` unions both. A transfer OUT needs no row: it lowers
-- inventory.quantity, and the newest-N-units window then drops precisely the
-- oldest lots, which IS the FIFO outcome.
--
-- Column list is unchanged, so CREATE OR REPLACE works and warehouse_rent /
-- warehouse_overview keep working without being touched.

CREATE OR REPLACE VIEW warehouse_stock_age AS
WITH all_lots AS (
    -- Route 1: bought. purchase.purchase_date is when the units landed.
    SELECT
        p.warehouse_id,
        pi.product_id,
        p.purchase_date     AS received_date,
        pi.quantity,
        'P'::TEXT           AS lot_kind,
        pi.purchase_item_id AS lot_id
    FROM purchase_item pi
    JOIN purchase p ON p.purchase_id = pi.purchase_id

    UNION ALL

    -- Route 2: transferred in, dated by origin_date rather than transfer_date
    -- so age survives the journey.
    SELECT
        t.to_warehouse_id,
        t.product_id,
        t.origin_date,
        t.quantity,
        'T'::TEXT,
        t.transfer_id
    FROM stock_transfer t
),
lots AS (
    SELECT
        l.warehouse_id,
        l.product_id,
        l.received_date,
        l.quantity,
        SUM(l.quantity) OVER (
            PARTITION BY l.warehouse_id, l.product_id
            -- lot_kind/lot_id are pure tie-breakers, so two lots received at
            -- the very same instant still stack in a stable order.
            ORDER BY l.received_date DESC, l.lot_kind DESC, l.lot_id DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cum_newest_first
    FROM all_lots l
),
remaining AS (
    SELECT
        l.warehouse_id,
        l.product_id,
        l.received_date,
        -- How much of this lot survives inside the newest-N-units window.
        LEAST(l.quantity, GREATEST(i.quantity - (l.cum_newest_first - l.quantity), 0))::INT AS units,
        GREATEST(EXTRACT(DAY FROM NOW() - l.received_date)::INT, 0) AS days_stored
    FROM lots l
    JOIN inventory i
      ON i.warehouse_id = l.warehouse_id
     AND i.product_id   = l.product_id
)
SELECT
    r.warehouse_id,
    w.name  AS warehouse_name,
    r.product_id,
    pr.name AS product_name,
    r.received_date,
    r.units,
    r.days_stored,
    storage_age_band(r.days_stored)       AS age_band,
    storage_age_multiplier(r.days_stored) AS rent_multiplier,
    ROUND(r.units * w.rent_per_unit_day * storage_age_multiplier(r.days_stored), 2) AS daily_rent
FROM remaining r
JOIN warehouse w  ON w.warehouse_id = r.warehouse_id
JOIN product   pr ON pr.product_id  = r.product_id
WHERE r.units > 0
ORDER BY r.days_stored DESC, r.warehouse_id;

-- Usage: SELECT * FROM warehouse_stock_age WHERE warehouse_id = 1;


-- ---------------------------------------------------------
-- 3. Move stock between hubs, in ONE transaction.
-- ---------------------------------------------------------
-- This exists as a function rather than as two writes from the browser for
-- two reasons:
--
--   ATOMICITY. Deducting the source and crediting the destination from the
--   frontend is two HTTP requests, i.e. two transactions. If the second one
--   fails -- and trg_enforce_warehouse_capacity WILL fail it when the
--   destination is full -- the units have already left the source and simply
--   cease to exist. Here both writes share one transaction, so a rejected
--   destination rolls the source back automatically.
--
--   PROVENANCE. Moved units keep their age. Under FIFO the units leaving a hub
--   are its oldest, so the loop below walks the source's lots oldest-first and
--   writes one stock_transfer row per lot, each carrying that lot's own receipt
--   date.
--
-- Returns the number of units moved.

CREATE OR REPLACE FUNCTION transfer_stock_api(
    p_product_id        INT,
    p_from_warehouse_id INT,
    p_to_warehouse_id   INT,
    p_quantity          INT
)
RETURNS INT AS $$
DECLARE
    v_source_qty INT;
    v_remaining  INT := p_quantity;
    v_take       INT;
    lot          RECORD;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Transfer quantity must be greater than zero';
    END IF;

    IF p_from_warehouse_id = p_to_warehouse_id THEN
        RAISE EXCEPTION 'Source and destination hub must be different';
    END IF;

    -- FOR UPDATE locks the source row for the rest of the transaction, so two
    -- transfers running at once cannot both read "50 available" and then each
    -- deduct 30.
    SELECT quantity INTO v_source_qty
    FROM inventory
    WHERE warehouse_id = p_from_warehouse_id AND product_id = p_product_id
    FOR UPDATE;

    IF v_source_qty IS NULL THEN
        RAISE EXCEPTION 'The source hub holds no stock of product_id % at all', p_product_id;
    ELSIF v_source_qty < p_quantity THEN
        RAISE EXCEPTION 'The source hub holds only % units of product_id % (need %)',
            v_source_qty, p_product_id, p_quantity;
    END IF;

    -- Split the move along the source's FIFO lots, oldest first. This reads
    -- warehouse_stock_age BEFORE `inventory` is touched below, because the view
    -- is derived from inventory and would shift underneath us otherwise.
    FOR lot IN
        SELECT sa.received_date, sa.units
        FROM warehouse_stock_age sa
        WHERE sa.warehouse_id = p_from_warehouse_id
          AND sa.product_id   = p_product_id
        ORDER BY sa.received_date ASC
    LOOP
        EXIT WHEN v_remaining = 0;
        v_take := LEAST(lot.units, v_remaining);

        INSERT INTO stock_transfer(from_warehouse_id, to_warehouse_id, product_id, quantity, origin_date)
        VALUES (p_from_warehouse_id, p_to_warehouse_id, p_product_id, v_take, lot.received_date);

        v_remaining := v_remaining - v_take;
    END LOOP;

    -- Any shortfall came from units the source itself could not date (stock
    -- hand-inserted into `inventory`, with no purchase or transfer behind it,
    -- or moved before this migration existed). They start their clock now --
    -- that is the honest answer, since nothing records when they arrived.
    IF v_remaining > 0 THEN
        INSERT INTO stock_transfer(from_warehouse_id, to_warehouse_id, product_id, quantity, origin_date)
        VALUES (p_from_warehouse_id, p_to_warehouse_id, p_product_id, v_remaining, NOW());
    END IF;

    UPDATE inventory
    SET quantity = quantity - p_quantity
    WHERE warehouse_id = p_from_warehouse_id AND product_id = p_product_id;

    -- Fires trg_enforce_warehouse_capacity. If the destination cannot take the
    -- units, the exception aborts this whole function -- including the
    -- deduction above and the stock_transfer rows.
    INSERT INTO inventory(warehouse_id, product_id, quantity)
    VALUES (p_to_warehouse_id, p_product_id, p_quantity)
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity = inventory.quantity + EXCLUDED.quantity;

    RETURN p_quantity;
END;
$$ LANGUAGE plpgsql;

-- Usage from frontend: supabase.rpc('transfer_stock_api',
--     { p_product_id: 1, p_from_warehouse_id: 1, p_to_warehouse_id: 2, p_quantity: 5 })


-- =========================================================
-- END OF MIGRATION
-- =========================================================
-- Check it worked -- move 5 units and watch the age travel with them:
--
--   SELECT warehouse_name, product_name, units, days_stored, age_band
--   FROM warehouse_stock_age WHERE product_id = 1;
--
--   SELECT transfer_stock_api(1, 2, 1, 5);   -- 5 earbuds, Chittagong -> Dhaka
--
--   -- The 5 units now show under Dhaka at their ORIGINAL age, not 0 days:
--   SELECT warehouse_name, product_name, units, days_stored, age_band
--   FROM warehouse_stock_age WHERE product_id = 1;
--
--   SELECT * FROM stock_transfer;
