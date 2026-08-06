-- =========================================================
-- TrackChain Database Schema
-- Integrated Supply Chain & Campaign Analytics System
-- =========================================================
-- HOW TO USE:
-- 1. Create a Supabase project (or any Postgres instance)
-- 2. Open the SQL editor and run this file top to bottom
-- 3. Everything below is commented so your team can explain
--    every line at the viva.
-- =========================================================
-- SECTION 1: CORE TABLES (Supply Chain)
-- =========================================================

CREATE TABLE supplier (
    supplier_id  SERIAL PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    phone        VARCHAR(20),
    address      TEXT
);

CREATE TABLE product (
    product_id   SERIAL PRIMARY KEY,
    supplier_id  INT NOT NULL REFERENCES supplier(supplier_id),
    name         VARCHAR(150) NOT NULL,
    category     VARCHAR(80),
    price        NUMERIC(10,2) NOT NULL CHECK (price >= 0)
);

-- capacity_units / rent_per_unit_day are the only stored data behind the
-- whole capacity + rent + aging feature in Section 5.5 -- everything else
-- there is derived. Capacity is measured in UNITS rather than m^3 because
-- `product` has no size or weight attribute, so units is the only honest
-- measure available; if product ever gains a volume column, only the
-- warehouse_capacity view needs to change.
-- `name` is UNIQUE because it is used as a lookup key, not just a label:
-- reduce_inventory() stamps the sourcing hub's name onto the shipment's
-- 'Packed' status row, and the order_fulfilment view (Section 10) joins that
-- name back to a warehouse. Two hubs sharing a name would make that join
-- ambiguous and duplicate every order row it produced.
-- rent_per_unit_day is DERIVED, never entered. Rent is a property of the
-- building in exactly the way capacity is, and the two are not independent:
-- bulk storage costs less per unit, so a bigger hub charges a lower rate. That
-- makes capacity_units -> rent_per_unit_day a functional dependency, and
-- storing a rate someone typed by hand would let the two disagree -- the
-- classic update anomaly, where enlarging a warehouse silently leaves it on its
-- old small-hub rate.
--
-- GENERATED ALWAYS ... STORED enforces it at the schema level: the column
-- cannot be inserted into or updated, and Postgres recomputes it whenever
-- capacity_units changes. Every view just reads the column as before.
--
-- The CASE is written inline rather than calling a function on purpose --
-- a generated expression must be immutable, and if it called a function whose
-- body was later edited, already-stored rates would silently drift out of step
-- with the new policy.
CREATE TABLE warehouse (
    warehouse_id      SERIAL PRIMARY KEY,
    name              VARCHAR(100) NOT NULL UNIQUE,
    location          VARCHAR(150),
    capacity_units    INT           NOT NULL DEFAULT 500 CHECK (capacity_units > 0),
    rent_per_unit_day NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE
            WHEN capacity_units <=  200 THEN 3.00   -- small hub, dearest per unit
            WHEN capacity_units <=  500 THEN 2.50
            WHEN capacity_units <= 1000 THEN 2.00
            ELSE                             1.50   -- bulk warehouse, cheapest
        END
    ) STORED
);

CREATE TABLE inventory (
    inventory_id SERIAL PRIMARY KEY,
    warehouse_id INT NOT NULL REFERENCES warehouse(warehouse_id),
    product_id   INT NOT NULL REFERENCES product(product_id),
    quantity     INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    UNIQUE (warehouse_id, product_id)  -- one row per product per warehouse
);

-- Moving stock between hubs is the one way units change location without a
-- purchase, so without this table `inventory` would simply show them in their
-- new home with no record of the move. Two consequences, both fixed by
-- recording it: the move itself becomes auditable, and -- because
-- warehouse_stock_age (Section 5.5.2) reconstructs age from arrival dates --
-- transferred units keep an arrival date instead of falling out of the rent
-- calculation entirely.
--
-- origin_date is the interesting column. transfer_date is when the move
-- happened; origin_date is the receipt date the moved units CARRY WITH THEM.
-- transfer_stock_api() (Section 8.3) splits each move along the source's FIFO
-- lots and writes one row per lot with that lot's own date, so a 90-day-old
-- unit is still 90 days old after it lands -- moving stock does not reset its
-- rent surcharge to zero.
--
-- Rows here do NOT move stock on their own; they record a move that
-- transfer_stock_api() also applies to `inventory`. Insert through that
-- function, never by hand.
CREATE TABLE stock_transfer (
    transfer_id       SERIAL PRIMARY KEY,
    from_warehouse_id INT NOT NULL REFERENCES warehouse(warehouse_id),
    to_warehouse_id   INT NOT NULL REFERENCES warehouse(warehouse_id),
    product_id        INT NOT NULL REFERENCES product(product_id),
    quantity          INT NOT NULL CHECK (quantity > 0),
    transfer_date     TIMESTAMP NOT NULL DEFAULT NOW(),
    origin_date       TIMESTAMP NOT NULL DEFAULT NOW(),
    CHECK (from_warehouse_id <> to_warehouse_id)
);


-- =========================================================
-- SECTION 2: CUSTOMER ORDER MANAGEMENT
-- =========================================================

CREATE TABLE customer (
    customer_id  SERIAL PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    contact      VARCHAR(100)
);

-- tracking_link_id is intentionally NOT here -- see order_attribution
-- below. Keeping marketing attribution out of the core order record
-- is cleaner: Order stays purely about the purchase itself.
CREATE TABLE "order" (
    order_id         SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customer(customer_id),
    order_date       TIMESTAMP NOT NULL DEFAULT NOW(),
    status           VARCHAR(30) NOT NULL DEFAULT 'PLACED'
);

CREATE TABLE order_item (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INT NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    product_id    INT NOT NULL REFERENCES product(product_id),
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0)
);


-- =========================================================
-- SECTION 3: CAMPAIGN ANALYTICS
-- =========================================================

CREATE TABLE campaign (
    campaign_id   SERIAL PRIMARY KEY,
    product_id    INT NOT NULL REFERENCES product(product_id),
    campaign_name VARCHAR(150) NOT NULL,
    start_date    DATE,
    end_date      DATE
);

CREATE TABLE tracking_link (
    link_id         SERIAL PRIMARY KEY,
    campaign_id     INT NOT NULL REFERENCES campaign(campaign_id),
    platform        VARCHAR(30) NOT NULL CHECK (platform IN ('Facebook','WhatsApp','Instagram','Email')),
    short_code      VARCHAR(20) UNIQUE NOT NULL,  -- e.g. FB10
    destination_url TEXT
);

-- Now that tracking_link exists, order_attribution can safely reference
-- both "order" and tracking_link. This is where a completed order gets
-- linked back to whichever campaign/platform caused it -- kept separate
-- from "order" itself on purpose (see comment on the order table above).
CREATE TABLE order_attribution (
    attribution_id  SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    link_id         INT NOT NULL REFERENCES tracking_link(link_id),
    attributed_time TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (order_id)  -- one attribution row per order in this simple model
);

-- Auto-generate a realistic, non-guessable short_code (e.g. "FB-A7K92")
-- if one wasn't supplied manually. Seed data can still hardcode simple
-- codes like "FB1" for easy demo typing -- this only fires when
-- short_code is left NULL, e.g. when your team creates a new campaign
-- live during the presentation.
CREATE OR REPLACE FUNCTION generate_short_code()
RETURNS TRIGGER AS $$
DECLARE
    v_prefix VARCHAR(4);
BEGIN
    IF NEW.short_code IS NOT NULL THEN
        RETURN NEW;
    END IF;

    v_prefix := CASE NEW.platform
        WHEN 'Facebook'  THEN 'FB'
        WHEN 'Instagram' THEN 'IG'
        WHEN 'WhatsApp'  THEN 'WA'
        WHEN 'Email'     THEN 'EM'
    END;

    NEW.short_code := v_prefix || '-' || upper(substr(md5(random()::text), 1, 5));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_generate_short_code
BEFORE INSERT ON tracking_link
FOR EACH ROW EXECUTE FUNCTION generate_short_code();

CREATE TABLE click (
    click_id    SERIAL PRIMARY KEY,
    link_id     INT NOT NULL REFERENCES tracking_link(link_id),
    click_time  TIMESTAMP NOT NULL DEFAULT NOW(),
    country     VARCHAR(80),
    device      VARCHAR(50),
    -- Nullable on purpose: Facebook/Instagram/WhatsApp clicks are from an
    -- anonymous public audience (NULL). Email clicks are from a known
    -- recipient, so we can fill this in.
    customer_id INT REFERENCES customer(customer_id)
);


-- =========================================================
-- SECTION 4: SHIPMENT TRACKING
-- =========================================================

CREATE TABLE shipment (
    shipment_id    SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES "order"(order_id),
    tracking_code  VARCHAR(20) UNIQUE,  -- filled in by trigger, see Section 6
    shipment_date  TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE shipment_status (
    status_id    SERIAL PRIMARY KEY,
    shipment_id  INT NOT NULL REFERENCES shipment(shipment_id) ON DELETE CASCADE,
    location     VARCHAR(150),
    status       VARCHAR(30) NOT NULL CHECK (
                    status IN ('Packed','In Transit','Out For Delivery','Delivered')
                ),
    updated_time TIMESTAMP NOT NULL DEFAULT NOW()
);


-- =========================================================
-- SECTION 4.5: PURCHASE MANAGEMENT
-- =========================================================


CREATE TABLE purchase (
    purchase_id   SERIAL PRIMARY KEY,
    supplier_id   INT NOT NULL REFERENCES supplier(supplier_id),
    warehouse_id  INT NOT NULL REFERENCES warehouse(warehouse_id),
    purchase_date TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE purchase_item (
    purchase_item_id SERIAL PRIMARY KEY,
    purchase_id  INT NOT NULL REFERENCES purchase(purchase_id) ON DELETE CASCADE,
    product_id   INT NOT NULL REFERENCES product(product_id),
    quantity     INT NOT NULL CHECK (quantity > 0),
    unit_cost    NUMERIC(10,2) NOT NULL CHECK (unit_cost >= 0)
);


-- =========================================================
-- SECTION 5: AUDIT LOGGING
-- =========================================================

CREATE TABLE audit_log (
    log_id     SERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    operation  VARCHAR(10) NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    record_id  INT,
    log_time   TIMESTAMP NOT NULL DEFAULT NOW()
);


-- =========================================================
-- SECTION 5.5: WAREHOUSE CAPACITY, STORAGE RENT & HUB ROUTING
-- =========================================================
-- Four connected pieces of logic, all built on the two extra columns on
-- `warehouse` (capacity_units, rent_per_unit_day) and nothing else:
--
--   1. CAPACITY   Each warehouse has a fixed, predefined size. Capacity
--                 itself never moves when stock arrives -- what changes
--                 is used/free space -- and stock can no longer be added
--                 past the limit (trigger 6.5).
--   2. RENT       Holding stock costs money per unit per day.
--   3. AGING      Units sitting too long cost MORE per day. Stock age is
--                 NOT stored -- it is reconstructed from purchase dates.
--   4. ROUTING    A customer order ships from the hub holding the oldest
--                 stock, i.e. the stock costing the most rent. So (4)
--                 exists to reduce the bill produced by (3).
--
-- This section sits before Section 6 because reduce_inventory() there now
-- calls pick_source_warehouse() defined below.


-- 5.5.1 The aging rent policy, as two tiny lookup functions. Keeping the
-- bands here rather than inline in the views means the pricing rule lives
-- in exactly one place: rent doubles on stale stock, triples on dead stock.

CREATE OR REPLACE FUNCTION storage_age_multiplier(p_days INT)
RETURNS NUMERIC AS $$
BEGIN
    RETURN CASE
        WHEN p_days > 90 THEN 3.0   -- dead stock: punitive
        WHEN p_days > 60 THEN 2.0   -- stale
        WHEN p_days > 30 THEN 1.5   -- aging
        ELSE                  1.0   -- fresh: base rate, no surcharge
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Usage: SELECT storage_age_multiplier(75);   -- 2.0

CREATE OR REPLACE FUNCTION storage_age_band(p_days INT)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE
        WHEN p_days > 90 THEN 'Dead stock'
        WHEN p_days > 60 THEN 'Stale'
        WHEN p_days > 30 THEN 'Aging'
        ELSE                  'Fresh'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Usage: SELECT storage_age_band(75);   -- 'Stale'


-- 5.5.2 How long has each unit been sitting in each warehouse?
--
-- `inventory` holds one running quantity per (warehouse, product) with no
-- arrival date, so stock age is stored nowhere. We rebuild it from the
-- purchase history instead:
--
--   * every unit that entered a warehouse came through a purchase_item,
--     and purchase.purchase_date is when it landed;
--   * assume FIFO -- the oldest units are the ones sold first;
--   * therefore the units STILL on hand are the NEWEST
--     inventory.quantity units purchased.
--
-- So we walk each (warehouse, product)'s lots newest-first keeping a
-- running total, and each lot keeps only the slice of itself falling
-- inside the on-hand window. A lot fully consumed by past sales
-- contributes 0 units and drops out via the final WHERE.
--
-- Units arrive by one of exactly two routes -- a purchase or a transfer in --
-- so `all_lots` below unions both. A transfer OUT needs no row: it lowers
-- inventory.quantity, and the newest-N-units window then drops precisely the
-- oldest lots, which IS the FIFO outcome.
--
-- Stock predating this schema (or hand-inserted straight into `inventory`) has
-- no lot at all. Those units are billed at the plain 1.0x rate rather than
-- silently dropped -- see billable_units in warehouse_rent (5.5.4).

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

    -- Route 2: transferred in. We date these by origin_date, NOT
    -- transfer_date: transfer_stock_api() copies each source lot's own receipt
    -- date onto the move, so age survives the journey. Dating them by
    -- transfer_date instead would let a hub wipe its rent surcharge just by
    -- shuffling dead stock between warehouses.
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


-- 5.5.3 Capacity: how full is each warehouse right now? This view is the
-- answer to "if inventory increases, what happens to capacity" -- capacity
-- is a property of the building and stays put; used_units rises and
-- free_units falls, and capacity_status escalates as it fills.

CREATE OR REPLACE VIEW warehouse_capacity AS
SELECT
    w.warehouse_id,
    w.name,
    w.location,
    w.capacity_units,
    COALESCE(SUM(i.quantity), 0)::INT                      AS used_units,
    (w.capacity_units - COALESCE(SUM(i.quantity), 0))::INT AS free_units,
    ROUND(COALESCE(SUM(i.quantity), 0) * 100.0 / w.capacity_units, 1) AS utilisation_pct,
    CASE
        WHEN COALESCE(SUM(i.quantity), 0) >  w.capacity_units        THEN 'OVER'
        WHEN COALESCE(SUM(i.quantity), 0) >= w.capacity_units * 0.90 THEN 'CRITICAL'
        WHEN COALESCE(SUM(i.quantity), 0) >= w.capacity_units * 0.75 THEN 'HIGH'
        ELSE                                                              'OK'
    END AS capacity_status
FROM warehouse w
LEFT JOIN inventory i ON i.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.name, w.location, w.capacity_units
ORDER BY utilisation_pct DESC;

-- Usage: SELECT * FROM warehouse_capacity;


-- 5.5.4 Rent: what does holding this stock cost per day?
--   base_daily_rent      = every unit at the plain rate (what rent WOULD be
--                          if nothing had gone stale)
--   surcharge_daily_rent = the extra caused purely by slow-moving stock
--   total_daily_rent     = what you actually pay

CREATE OR REPLACE VIEW warehouse_rent AS
WITH onhand AS (
    SELECT warehouse_id, COALESCE(SUM(quantity), 0)::INT AS units
    FROM inventory
    GROUP BY warehouse_id
),
aged AS (
    SELECT
        warehouse_id,
        SUM(units)::INT              AS lot_units,
        SUM(units * rent_multiplier) AS weighted_units,
        SUM(CASE WHEN days_stored > 30 THEN units ELSE 0 END)::INT AS overdue_units,
        MAX(days_stored)::INT        AS oldest_days
    FROM warehouse_stock_age
    GROUP BY warehouse_id
),
billing AS (
    SELECT
        w.warehouse_id,
        w.name,
        w.rent_per_unit_day,
        COALESCE(o.units, 0)         AS on_hand_units,
        COALESCE(a.overdue_units, 0) AS overdue_units,
        COALESCE(a.oldest_days, 0)   AS oldest_days,
        -- Units billed at their own aged rate, PLUS any on-hand units with no
        -- lot behind them at all, billed at the plain 1.0x rate. Purchases and
        -- transfers both leave a lot now, so that remainder should only ever
        -- cover inventory hand-inserted straight into the table -- but keeping
        -- it means the bill still reconciles with on_hand_units if any turns
        -- up, instead of quietly under-billing it.
        COALESCE(a.weighted_units, 0)
          + GREATEST(COALESCE(o.units, 0) - COALESCE(a.lot_units, 0), 0) AS billable_units
    FROM warehouse w
    LEFT JOIN onhand o ON o.warehouse_id = w.warehouse_id
    LEFT JOIN aged   a ON a.warehouse_id = w.warehouse_id
)
SELECT
    warehouse_id,
    name,
    rent_per_unit_day,
    on_hand_units,
    overdue_units,
    oldest_days,
    ROUND(on_hand_units                    * rent_per_unit_day,      2) AS base_daily_rent,
    ROUND((billable_units - on_hand_units) * rent_per_unit_day,      2) AS surcharge_daily_rent,
    ROUND(billable_units                   * rent_per_unit_day,      2) AS total_daily_rent,
    ROUND(billable_units                   * rent_per_unit_day * 30, 2) AS total_monthly_rent
FROM billing
ORDER BY total_daily_rent DESC;

-- Usage: SELECT * FROM warehouse_rent;


-- One flat row per warehouse with capacity AND rent side by side -- this is
-- what the Warehouse page reads, so it needs a single request.
CREATE OR REPLACE VIEW warehouse_overview AS
SELECT
    c.warehouse_id,
    c.name,
    c.location,
    c.capacity_units,
    c.used_units,
    c.free_units,
    c.utilisation_pct,
    c.capacity_status,
    r.rent_per_unit_day,
    r.overdue_units,
    r.oldest_days,
    r.base_daily_rent,
    r.surcharge_daily_rent,
    r.total_daily_rent,
    r.total_monthly_rent
FROM warehouse_capacity c
JOIN warehouse_rent     r ON r.warehouse_id = c.warehouse_id
ORDER BY c.utilisation_pct DESC;

-- Usage: SELECT * FROM warehouse_overview;


-- 5.5.5 Routing: which hub does a customer order ship from?
--
-- Rule: among the hubs that can cover the whole line on their own, ship from
-- the one whose stock of that product is accruing the most aging surcharge --
-- because relieving that surcharge is the entire point of routing this way.
--
-- The ranking metric is SUM(units * (rent_multiplier - 1)), i.e. the EXTRA
-- units of rent this hub pays per day purely because its stock is old. Fresh
-- stock scores 0 no matter how much of it there is. The obvious alternative,
-- MAX(days_stored), is wrong: it looks at the single oldest sliver and ignores
-- how much of it there is, so a hub holding one 100-day-old unit alongside 999
-- fresh ones would outrank a hub holding 500 units at 95 days -- and shipping
-- from the first hub saves almost nothing. SUM(units * rent_multiplier) is
-- wrong too, in the opposite direction: it is dominated by sheer volume, so a
-- big fresh hub would beat a small stale one.
--
-- Ties (typically every candidate fresh, so every score 0) fall through to the
-- oldest single lot, then to who has most to spare, then to warehouse_id so
-- the choice is deterministic.
--
-- Returns NULL when no single hub can cover the quantity. Splitting one
-- order line across two hubs is deliberately out of scope -- it would need
-- a per-item fulfilment record, i.e. a new table.

CREATE OR REPLACE FUNCTION pick_source_warehouse(p_product_id INT, p_quantity INT)
RETURNS INT AS $$
DECLARE
    v_warehouse_id INT;
BEGIN
    SELECT i.warehouse_id INTO v_warehouse_id
    FROM inventory i
    LEFT JOIN (
        SELECT sa.warehouse_id,
               sa.product_id,
               SUM(sa.units * (sa.rent_multiplier - 1)) AS surcharge_units,
               MAX(sa.days_stored)                      AS oldest_days
        FROM warehouse_stock_age sa
        WHERE sa.product_id = p_product_id
        GROUP BY sa.warehouse_id, sa.product_id
    ) a ON a.warehouse_id = i.warehouse_id
       AND a.product_id   = i.product_id
    WHERE i.product_id = p_product_id
      AND i.quantity  >= p_quantity
    ORDER BY COALESCE(a.surcharge_units, 0) DESC,  -- most surcharge relieved
             COALESCE(a.oldest_days, 0)     DESC,  -- then the oldest lot
             i.quantity DESC,                      -- then most to spare
             i.warehouse_id                        -- deterministic tie-break
    LIMIT 1;

    RETURN v_warehouse_id;
END;
$$ LANGUAGE plpgsql;

-- Usage: SELECT pick_source_warehouse(1, 5);


-- Same ranking, but showing EVERY candidate hub and flagging the winner,
-- so the Warehouse page can show WHY a hub was picked rather than just
-- naming it.
CREATE OR REPLACE FUNCTION hub_routing_preview(p_product_id INT, p_quantity INT DEFAULT 1)
RETURNS TABLE(
    warehouse_id    INT,
    warehouse_name  VARCHAR,
    on_hand         INT,
    oldest_days     INT,
    surcharge_units NUMERIC,
    utilisation_pct NUMERIC,
    can_fulfil      BOOLEAN,
    is_chosen       BOOLEAN
) AS $$
DECLARE
    v_chosen INT;
BEGIN
    v_chosen := pick_source_warehouse(p_product_id, p_quantity);

    RETURN QUERY
    SELECT
        i.warehouse_id,
        w.name,
        i.quantity,
        COALESCE(a.oldest_days, 0)::INT,
        COALESCE(a.surcharge_units, 0),
        c.utilisation_pct,
        (i.quantity >= p_quantity),
        -- COALESCE so a product no hub can cover reports FALSE rather than NULL.
        COALESCE(i.warehouse_id = v_chosen, FALSE)
    FROM inventory i
    JOIN warehouse          w ON w.warehouse_id = i.warehouse_id
    JOIN warehouse_capacity c ON c.warehouse_id = i.warehouse_id
    LEFT JOIN (
        SELECT sa.warehouse_id,
               sa.product_id,
               SUM(sa.units * (sa.rent_multiplier - 1)) AS surcharge_units,
               MAX(sa.days_stored)                      AS oldest_days
        FROM warehouse_stock_age sa
        WHERE sa.product_id = p_product_id
        GROUP BY sa.warehouse_id, sa.product_id
    ) a ON a.warehouse_id = i.warehouse_id
       AND a.product_id   = i.product_id
    WHERE i.product_id = p_product_id
    -- Same ranking as pick_source_warehouse, so the table explains the winner
    -- rather than merely agreeing with it.
    ORDER BY COALESCE(i.warehouse_id = v_chosen, FALSE) DESC,
             COALESCE(a.surcharge_units, 0) DESC,
             COALESCE(a.oldest_days, 0) DESC,
             i.quantity DESC;
END;
$$ LANGUAGE plpgsql;

-- Usage from frontend: supabase.rpc('hub_routing_preview', { p_product_id: 1, p_quantity: 3 })


-- =========================================================
-- SECTION 6: TRIGGERS (PL/pgSQL) — this is what makes the
-- project "backend-heavy" as your rubric asks for.
-- =========================================================

-- 6.1 Audit trigger functions.
-- The "record_id" column name differs per table (order_id,
-- inventory_id...), so rather than one generic function guessing
-- a column name, we write one small trigger function per table.
-- Still ONE reusable pattern, just explicit about which id column
-- it logs -- this is the standard, safe way to do this in Postgres.

CREATE OR REPLACE FUNCTION log_audit_order()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('order', TG_OP, OLD.order_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('order', TG_OP, NEW.order_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_order
AFTER INSERT OR UPDATE OR DELETE ON "order"
FOR EACH ROW EXECUTE FUNCTION log_audit_order();

CREATE OR REPLACE FUNCTION log_audit_inventory()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('inventory', TG_OP, OLD.inventory_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('inventory', TG_OP, NEW.inventory_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_inventory
AFTER INSERT OR UPDATE OR DELETE ON inventory
FOR EACH ROW EXECUTE FUNCTION log_audit_inventory();

CREATE OR REPLACE FUNCTION log_audit_purchase()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('purchase', TG_OP, OLD.purchase_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('purchase', TG_OP, NEW.purchase_id);
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_purchase
AFTER INSERT OR UPDATE OR DELETE ON purchase
FOR EACH ROW EXECUTE FUNCTION log_audit_purchase();


-- Deduct sold units from a SPECIFIC hub -- the one pick_source_warehouse()
-- (5.5.5) chooses, i.e. whichever holds the oldest stock of that product.
--
-- An earlier version of this function did
--     SELECT quantity FROM inventory WHERE product_id = X LIMIT 1
-- with no warehouse filter and no ORDER BY, so it checked and then deducted
-- from an ARBITRARY warehouse -- and could reject a perfectly fillable
-- order just because the row it happened to pick was the empty one.
--
-- It also RECORDS the decision, with no new column: shipment_status
-- already has a `location` field which the auto-created 'Packed' row left
-- NULL. Writing the hub name there makes "which hub did this order ship
-- from" a permanent, queryable fact -- see the order_fulfilment view in
-- Section 10.
CREATE OR REPLACE FUNCTION reduce_inventory()
RETURNS TRIGGER AS $$
DECLARE
    v_warehouse_id    INT;
    v_hub_name        VARCHAR;
    v_total_available INT;
BEGIN
    v_warehouse_id := pick_source_warehouse(NEW.product_id, NEW.quantity);

    IF v_warehouse_id IS NULL THEN
        SELECT COALESCE(SUM(quantity), 0) INTO v_total_available
        FROM inventory WHERE product_id = NEW.product_id;

        IF v_total_available = 0 THEN
            RAISE EXCEPTION 'No hub holds any stock of product_id %', NEW.product_id;
        ELSIF v_total_available < NEW.quantity THEN
            -- Genuinely not enough stock anywhere: the same case the original
            -- reduce_inventory() reported as "Insufficient stock".
            RAISE EXCEPTION 'Insufficient stock for product_id % (need %, only % across all hubs)',
                NEW.product_id, NEW.quantity, v_total_available;
        ELSE
            -- Enough stock exists, just not in one place.
            RAISE EXCEPTION
                'No single hub can fulfil % units of product_id % -- % units exist but are split across hubs. Transfer stock into one hub first.',
                NEW.quantity, NEW.product_id, v_total_available;
        END IF;
    END IF;

    UPDATE inventory
    SET quantity = quantity - NEW.quantity
    WHERE warehouse_id = v_warehouse_id
      AND product_id   = NEW.product_id;

    SELECT name INTO v_hub_name FROM warehouse WHERE warehouse_id = v_warehouse_id;

    -- A multi-item order whose lines come from different hubs is marked
    -- 'Multiple hubs' rather than pretending it had a single origin.
    UPDATE shipment_status ss
    SET location = CASE
            WHEN ss.location IS NULL      THEN v_hub_name
            WHEN ss.location = v_hub_name THEN ss.location
            ELSE 'Multiple hubs'
        END
    FROM shipment s
    WHERE s.shipment_id = ss.shipment_id
      AND s.order_id    = NEW.order_id
      AND ss.status     = 'Packed';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reduce_inventory
AFTER INSERT ON order_item
FOR EACH ROW EXECUTE FUNCTION reduce_inventory();


CREATE OR REPLACE FUNCTION increase_inventory()
RETURNS TRIGGER AS $$
DECLARE
    v_warehouse_id INT;
BEGIN
    SELECT warehouse_id INTO v_warehouse_id
    FROM purchase
    WHERE purchase_id = NEW.purchase_id;

    INSERT INTO inventory(warehouse_id, product_id, quantity)
    VALUES (v_warehouse_id, NEW.product_id, NEW.quantity)
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity = inventory.quantity + EXCLUDED.quantity;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increase_inventory
AFTER INSERT ON purchase_item
FOR EACH ROW EXECUTE FUNCTION increase_inventory();


-- 6.2a Reject a purchase_item whose product isn't actually supplied by the
-- purchase's supplier. Without this, "supplier_id" on purchase is pure

CREATE OR REPLACE FUNCTION check_purchase_supplier_match()
RETURNS TRIGGER AS $$
DECLARE
    v_purchase_supplier_id INT;
    v_product_supplier_id  INT;
BEGIN
    SELECT supplier_id INTO v_purchase_supplier_id FROM purchase WHERE purchase_id = NEW.purchase_id;
    SELECT supplier_id INTO v_product_supplier_id  FROM product  WHERE product_id  = NEW.product_id;

    IF v_product_supplier_id IS DISTINCT FROM v_purchase_supplier_id THEN
        RAISE EXCEPTION 'Product % belongs to supplier %, not the purchase''s supplier % -- record this purchase under the product''s own supplier',
            NEW.product_id, v_product_supplier_id, v_purchase_supplier_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_purchase_supplier_match
BEFORE INSERT ON purchase_item
FOR EACH ROW EXECUTE FUNCTION check_purchase_supplier_match();


-- 6.2b Mirror image of trg_increase_inventory: reverse the inventory
-- increase if a purchase is ever deleted. Attached to `purchase` itself
-- and fired BEFORE DELETE, so it runs -- and can still see the
-- purchase_item rows -- before the ON DELETE CASCADE removes them.
-- Deleting a purchase whose stock has already been sold will fail
-- (inventory's quantity >= 0 CHECK stops it going negative), same
-- protective behavior as reduce_inventory() on the sales side.
CREATE OR REPLACE FUNCTION reverse_inventory_on_purchase_delete()
RETURNS TRIGGER AS $$
DECLARE
    item RECORD;
BEGIN
    FOR item IN SELECT product_id, quantity FROM purchase_item WHERE purchase_id = OLD.purchase_id LOOP
        UPDATE inventory
        SET quantity = quantity - item.quantity
        WHERE warehouse_id = OLD.warehouse_id AND product_id = item.product_id;
    END LOOP;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reverse_inventory_on_purchase_delete
BEFORE DELETE ON purchase
FOR EACH ROW EXECUTE FUNCTION reverse_inventory_on_purchase_delete();


-- 6.2c Enforce each warehouse's predefined capacity (Section 5.5).
-- Guarding `inventory` rather than `purchase_item` is deliberate: EVERY
-- route that adds stock ends up writing here -- purchases (through
-- increase_inventory above) and the Transfer Stock screen (which updates
-- inventory directly). One trigger therefore closes both doors, whereas a
-- trigger on purchase_item would have left transfers free to overflow.
CREATE OR REPLACE FUNCTION enforce_warehouse_capacity()
RETURNS TRIGGER AS $$
DECLARE
    v_name     VARCHAR;
    v_capacity INT;
    v_others   INT;   -- units in this warehouse EXCLUDING the row being written
    v_used     INT;   -- units in this warehouse INCLUDING it, i.e. the real total
    v_delta    INT;   -- how many units this change actually adds
    v_prior    INT := 0;  -- units this row ALREADY contributed to this warehouse
BEGIN
    -- Only an increase in what THIS warehouse holds can breach its capacity.
    -- Skipping the check otherwise keeps sales, transfers-out and manual
    -- corrections working, and crucially lets an already-overfull warehouse
    -- still be drained.
    --
    -- The warehouse test matters as much as the quantity one: an UPDATE that
    -- moves a row to a DIFFERENT warehouse dumps all of its units into that
    -- warehouse even though NEW.quantity never rose, so testing the quantity
    -- delta alone would wave the move straight through and let the destination
    -- overflow. On such a move v_prior stays 0, so the full NEW.quantity is
    -- checked against the destination -- which is exactly right, since every
    -- one of those units is new to it.
    --
    -- The IFs are nested rather than ANDed into one condition on purpose. OLD
    -- does not exist on an INSERT, and `TG_OP = 'UPDATE' AND OLD.x = ...` is a
    -- SINGLE SQL expression -- SQL does not promise to stop evaluating an AND
    -- once the left side is false, so on an INSERT that form can still reach
    -- OLD and fail. Only the outer IF runs on an INSERT, and it never
    -- mentions OLD.
    IF TG_OP = 'UPDATE' THEN
        IF NEW.warehouse_id = OLD.warehouse_id THEN
            IF NEW.quantity <= OLD.quantity THEN
                RETURN NEW;
            END IF;
            v_prior := OLD.quantity;
        END IF;
    END IF;

    SELECT w.name, w.capacity_units
      INTO v_name, v_capacity
    FROM warehouse w
    WHERE w.warehouse_id = NEW.warehouse_id;

    SELECT COALESCE(SUM(i.quantity), 0)
      INTO v_others
    FROM inventory i
    WHERE i.warehouse_id = NEW.warehouse_id
      AND i.inventory_id IS DISTINCT FROM NEW.inventory_id;

    -- v_others deliberately excludes this row, but the numbers we REPORT must
    -- be the warehouse's real totals -- otherwise an update to an existing row
    -- reads as "60 free, needed 50" and looks like it should have succeeded.
    -- v_prior is 0 on an insert and on a move, because in both cases this row
    -- was contributing nothing to THIS warehouse before now.
    v_used  := v_others + v_prior;
    v_delta := NEW.quantity - v_prior;

    IF v_others + NEW.quantity > v_capacity THEN
        RAISE EXCEPTION
            'Warehouse "%" is out of space: capacity % units, % already stored, % free -- this change adds % more units',
            -- GREATEST because a warehouse loaded before this trigger existed
            -- can already be over capacity, and "-20 free" reads as a bug.
            v_name, v_capacity, v_used, GREATEST(v_capacity - v_used, 0), v_delta;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enforce_warehouse_capacity
BEFORE INSERT OR UPDATE ON inventory
FOR EACH ROW EXECUTE FUNCTION enforce_warehouse_capacity();


-- 6.2d The other way to break capacity is to shrink the building instead
-- of growing the stock, so block that too.
CREATE OR REPLACE FUNCTION check_capacity_not_below_stock()
RETURNS TRIGGER AS $$
DECLARE
    v_used INT;
BEGIN
    IF NEW.capacity_units >= OLD.capacity_units THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(SUM(quantity), 0) INTO v_used
    FROM inventory WHERE warehouse_id = NEW.warehouse_id;

    IF NEW.capacity_units < v_used THEN
        RAISE EXCEPTION
            'Cannot shrink "%" to % units -- it already stores % units. Move stock out first.',
            NEW.name, NEW.capacity_units, v_used;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_capacity_not_below_stock
BEFORE UPDATE ON warehouse
FOR EACH ROW EXECUTE FUNCTION check_capacity_not_below_stock();


-- 6.3 Auto-generate shipment tracking code (TRK + shipment_id)
-- whenever a new shipment is created -- matches your spec's
-- "TRK3001" logic, done automatically instead of in app code.
CREATE OR REPLACE FUNCTION generate_tracking_code()
RETURNS TRIGGER AS $$
BEGIN
    NEW.tracking_code := 'TRK' || NEW.shipment_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_generate_tracking_code
BEFORE INSERT ON shipment
FOR EACH ROW EXECUTE FUNCTION generate_tracking_code();


-- 6.4 Auto-create a shipment the moment an order is placed, starting it
-- off with a 'Packed' status. This matches the flow described in the
-- project brief (Order -> Shipment Created -> Tracking Code Generated ->
-- Delivered): before this trigger, a shipment only ever existed if
-- someone inserted one by hand (as seed_data.sql used to). Now every
-- order automatically enters the fulfillment pipeline, and
-- trg_generate_tracking_code (above) tags it with a TRK<id> code as
-- soon as it's created.
CREATE OR REPLACE FUNCTION create_shipment_for_order()
RETURNS TRIGGER AS $$
DECLARE
    v_shipment_id INT;
BEGIN
    INSERT INTO shipment(order_id)
    VALUES (NEW.order_id)
    RETURNING shipment_id INTO v_shipment_id;

    INSERT INTO shipment_status(shipment_id, status)
    VALUES (v_shipment_id, 'Packed');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_create_shipment_on_order
AFTER INSERT ON "order"
FOR EACH ROW EXECUTE FUNCTION create_shipment_for_order();


-- =========================================================
-- SECTION 7: FUNCTIONS (for analytics -- "combined business
-- questions" from your spec)
-- =========================================================

-- 7.1 Revenue generated by a specific campaign
CREATE OR REPLACE FUNCTION campaign_revenue(p_campaign_id INT)
RETURNS NUMERIC AS $$
DECLARE
    total NUMERIC;
BEGIN
    SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
    INTO total
    FROM order_attribution oa
    JOIN tracking_link tl ON tl.link_id = oa.link_id
    JOIN order_item oi ON oi.order_id = oa.order_id
    WHERE tl.campaign_id = p_campaign_id;

    RETURN total;
END;
$$ LANGUAGE plpgsql;

-- Usage: SELECT campaign_revenue(1);

-- 7.2 Low-stock products (quantity below a threshold)
CREATE OR REPLACE FUNCTION low_stock_products(p_threshold INT DEFAULT 10)
RETURNS TABLE(product_id INT, product_name VARCHAR, quantity INT) AS $$
BEGIN
    RETURN QUERY
    SELECT p.product_id, p.name, i.quantity
    FROM inventory i
    JOIN product p ON p.product_id = i.product_id
    WHERE i.quantity < p_threshold
    ORDER BY i.quantity ASC;
END;
$$ LANGUAGE plpgsql;

-- Usage: SELECT * FROM low_stock_products(10);


-- =========================================================
-- SECTION 8: PROCEDURE (transaction-style operation)
-- =========================================================

-- Places an order with a single item in one transaction:
-- checks stock, inserts the order, inserts the order_item
-- (which fires trg_reduce_inventory automatically).
CREATE OR REPLACE PROCEDURE place_order(
    p_customer_id INT,
    p_tracking_link_id INT,
    p_product_id INT,
    p_quantity INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id INT;
    v_price NUMERIC;
BEGIN
    SELECT price INTO v_price FROM product WHERE product_id = p_product_id;

    INSERT INTO "order"(customer_id)
    VALUES (p_customer_id)
    RETURNING order_id INTO v_order_id;

    INSERT INTO order_item(order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    IF p_tracking_link_id IS NOT NULL THEN
        INSERT INTO order_attribution(order_id, link_id)
        VALUES (v_order_id, p_tracking_link_id);
    END IF;

    RAISE NOTICE 'Order % placed successfully.', v_order_id;
END;
$$;

-- Usage: CALL place_order(1, 1, 1, 2);


-- 8.1 Frontend-callable version.
-- Supabase's auto-generated API calls FUNCTIONS (via "rpc"), not raw
-- PROCEDURES, and functions can return a value directly (the new
-- order_id) which the frontend needs to show a confirmation. This does
-- the same job as place_order() above -- keep the procedure for SQL
-- Editor demos/viva, use this function from the website.
CREATE OR REPLACE FUNCTION place_order_api(
    p_customer_id INT,
    p_tracking_link_id INT,
    p_product_id INT,
    p_quantity INT
)
RETURNS INT AS $$
DECLARE
    v_order_id INT;
    v_price NUMERIC;
BEGIN
    SELECT price INTO v_price FROM product WHERE product_id = p_product_id;

    INSERT INTO "order"(customer_id)
    VALUES (p_customer_id)
    RETURNING order_id INTO v_order_id;

    INSERT INTO order_item(order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    IF p_tracking_link_id IS NOT NULL THEN
        INSERT INTO order_attribution(order_id, link_id)
        VALUES (v_order_id, p_tracking_link_id);
    END IF;

    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql;

-- Usage from frontend: supabase.rpc('place_order_api', { p_customer_id: 1, ... })


-- 8.2 Mirror image of place_order/place_order_api, for the inbound
-- (Purchasing Officer) side: one supplier, one warehouse, one product,
-- one purchase in a single transaction (fires trg_increase_inventory).
CREATE OR REPLACE PROCEDURE place_purchase(
    p_supplier_id INT,
    p_warehouse_id INT,
    p_product_id INT,
    p_quantity INT,
    p_unit_cost NUMERIC
)
LANGUAGE plpgsql AS $$
DECLARE
    v_purchase_id INT;
BEGIN
    INSERT INTO purchase(supplier_id, warehouse_id)
    VALUES (p_supplier_id, p_warehouse_id)
    RETURNING purchase_id INTO v_purchase_id;

    INSERT INTO purchase_item(purchase_id, product_id, quantity, unit_cost)
    VALUES (v_purchase_id, p_product_id, p_quantity, p_unit_cost);

    RAISE NOTICE 'Purchase % recorded successfully.', v_purchase_id;
END;
$$;

-- Usage: CALL place_purchase(1, 1, 1, 500, 12.50);

CREATE OR REPLACE FUNCTION place_purchase_api(
    p_supplier_id INT,
    p_warehouse_id INT,
    p_product_id INT,
    p_quantity INT,
    p_unit_cost NUMERIC
)
RETURNS INT AS $$
DECLARE
    v_purchase_id INT;
BEGIN
    INSERT INTO purchase(supplier_id, warehouse_id)
    VALUES (p_supplier_id, p_warehouse_id)
    RETURNING purchase_id INTO v_purchase_id;

    INSERT INTO purchase_item(purchase_id, product_id, quantity, unit_cost)
    VALUES (v_purchase_id, p_product_id, p_quantity, p_unit_cost);

    RETURN v_purchase_id;
END;
$$ LANGUAGE plpgsql;

-- Usage from frontend: supabase.rpc('place_purchase_api', { p_supplier_id: 1, ... })


-- 8.3 Move stock between hubs, in ONE transaction.
--
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
--   date. warehouse_stock_age then reads those dates at the destination and the
--   stock stays exactly as old as it was. Dating the arrivals "now" instead
--   would let anyone clear a dead-stock rent surcharge just by bouncing the
--   pallet to the next hub and back.
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
    -- hand-inserted into `inventory`, with no purchase or transfer behind it).
    -- They start their clock now -- that is the honest answer, since nothing
    -- records when they actually arrived.
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
-- SECTION 9: CURSOR EXAMPLE
-- =========================================================

-- Loops through all shipments that are NOT yet "Delivered"
-- and returns how many days they've been in transit.
-- Cursors are rarely "necessary" in Postgres (most things can
-- be done with a set-based query), but your rubric explicitly
-- asks for one, so this demonstrates the concept clearly.
CREATE OR REPLACE FUNCTION pending_shipment_report()
RETURNS TABLE(shipment_id INT, tracking_code VARCHAR, days_pending NUMERIC) AS $$
DECLARE
    cur CURSOR FOR
        SELECT s.shipment_id, s.tracking_code, s.shipment_date
        FROM shipment s
        WHERE NOT EXISTS (
            SELECT 1 FROM shipment_status ss
            WHERE ss.shipment_id = s.shipment_id AND ss.status = 'Delivered'
        );
    rec RECORD;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO rec;
        EXIT WHEN NOT FOUND;

        shipment_id := rec.shipment_id;
        tracking_code := rec.tracking_code;
        days_pending := EXTRACT(DAY FROM NOW() - rec.shipment_date);
        RETURN NEXT;
    END LOOP;
    CLOSE cur;
END;
$$ LANGUAGE plpgsql;

-- Usage: SELECT * FROM pending_shipment_report();


-- =========================================================
-- SECTION 10: ANALYTICS VIEWS (the "combined business
-- questions" -- the strongest feature of the project)
-- =========================================================

-- Which campaign generated the most orders / revenue?
CREATE OR REPLACE VIEW campaign_performance AS
SELECT
    c.campaign_id,
    c.campaign_name,
    tl.platform,
    COUNT(DISTINCT cl.click_id) AS total_clicks,
    COUNT(DISTINCT oa.order_id) AS total_orders,
    COALESCE(SUM(oi.quantity * oi.unit_price), 0) AS total_revenue
FROM campaign c
LEFT JOIN tracking_link tl ON tl.campaign_id = c.campaign_id
LEFT JOIN click cl ON cl.link_id = tl.link_id
LEFT JOIN order_attribution oa ON oa.link_id = tl.link_id
LEFT JOIN order_item oi ON oi.order_id = oa.order_id
GROUP BY c.campaign_id, c.campaign_name, tl.platform
ORDER BY total_revenue DESC;

-- Which platform performs best overall?
CREATE OR REPLACE VIEW platform_performance AS
SELECT
    tl.platform,
    COUNT(DISTINCT cl.click_id) AS total_clicks,
    COUNT(DISTINCT oa.order_id) AS total_orders,
    COALESCE(SUM(oi.quantity * oi.unit_price), 0) AS total_revenue
FROM tracking_link tl
LEFT JOIN click cl ON cl.link_id = tl.link_id
LEFT JOIN order_attribution oa ON oa.link_id = tl.link_id
LEFT JOIN order_item oi ON oi.order_id = oa.order_id
GROUP BY tl.platform
ORDER BY total_revenue DESC;

-- Which supplier provides the most products?
CREATE OR REPLACE VIEW supplier_product_count AS
SELECT s.supplier_id, s.name, COUNT(p.product_id) AS product_count
FROM supplier s
LEFT JOIN product p ON p.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.name
ORDER BY product_count DESC;

-- Purchase history, flattened for the Purchasing Officer's screen --
-- who supplied it, into which warehouse, what it cost.
CREATE OR REPLACE VIEW purchase_history AS
SELECT
    pi.purchase_item_id,
    p.purchase_id,
    p.purchase_date,
    s.name AS supplier_name,
    w.name AS warehouse_name,
    pr.name AS product_name,
    pi.quantity,
    pi.unit_cost,
    (pi.quantity * pi.unit_cost) AS total_cost
FROM purchase_item pi
JOIN purchase p ON p.purchase_id = pi.purchase_id
JOIN supplier s ON s.supplier_id = p.supplier_id
JOIN warehouse w ON w.warehouse_id = p.warehouse_id
JOIN product pr ON pr.product_id = pi.product_id
ORDER BY p.purchase_date DESC;

-- Every order with the hub it actually shipped from, read back out of the
-- 'Packed' shipment_status row that reduce_inventory() (Section 6) stamped.
-- source_warehouse_id is matched on NAME because no foreign key is possible
-- without adding a column -- acceptable here since warehouse.name is exactly
-- what reduce_inventory() wrote, and it is the price of keeping the existing
-- table structure untouched. Orders placed before the routing logic existed
-- have source_hub = NULL.
CREATE OR REPLACE VIEW order_fulfilment AS
SELECT
    o.order_id,
    o.order_date,
    c.name  AS customer_name,
    s.tracking_code,
    packed.location AS source_hub,
    sw.warehouse_id AS source_warehouse_id,
    COALESCE((SELECT SUM(oi.quantity) FROM order_item oi WHERE oi.order_id = o.order_id), 0)::INT AS units,
    latest.status AS shipment_status
FROM "order" o
JOIN customer c ON c.customer_id = o.customer_id
LEFT JOIN shipment s ON s.order_id = o.order_id
LEFT JOIN shipment_status packed
       ON packed.shipment_id = s.shipment_id AND packed.status = 'Packed'
LEFT JOIN warehouse sw ON sw.name = packed.location
LEFT JOIN LATERAL (
    SELECT ss.status
    FROM shipment_status ss
    WHERE ss.shipment_id = s.shipment_id
    ORDER BY ss.updated_time DESC, ss.status_id DESC
    LIMIT 1
) latest ON TRUE
ORDER BY o.order_date DESC;

-- Usage: SELECT * FROM order_fulfilment WHERE source_warehouse_id = 1;

-- =========================================================
-- SECTION 11: ACCESS FOR THE FRONTEND (DEMO SETTING ONLY)
-- =========================================================
-- Supabase enables Row Level Security by default on some setups, which
-- BLOCKS all API access until you write policies. For a closed academic
-- demo project (no real customers, no sensitive data), the simplest
-- correct choice is to disable RLS so your frontend can read/write
-- through the auto-generated API.
--
-- IMPORTANT: this is fine for a course project. It would NOT be fine for
-- a real production app with real user data -- mention this trade-off
-- explicitly in your report as a known simplification.

ALTER TABLE supplier        DISABLE ROW LEVEL SECURITY;
ALTER TABLE product         DISABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse       DISABLE ROW LEVEL SECURITY;
ALTER TABLE inventory       DISABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfer  DISABLE ROW LEVEL SECURITY;
ALTER TABLE customer        DISABLE ROW LEVEL SECURITY;
ALTER TABLE "order"          DISABLE ROW LEVEL SECURITY;
ALTER TABLE order_item       DISABLE ROW LEVEL SECURITY;
ALTER TABLE campaign         DISABLE ROW LEVEL SECURITY;
ALTER TABLE tracking_link    DISABLE ROW LEVEL SECURITY;
ALTER TABLE order_attribution DISABLE ROW LEVEL SECURITY;
ALTER TABLE click             DISABLE ROW LEVEL SECURITY;
ALTER TABLE shipment        DISABLE ROW LEVEL SECURITY;
ALTER TABLE shipment_status DISABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log       DISABLE ROW LEVEL SECURITY;
ALTER TABLE purchase        DISABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_item   DISABLE ROW LEVEL SECURITY;

-- =========================================================
-- END OF SCHEMA
-- =========================================================
