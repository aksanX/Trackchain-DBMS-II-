-- =========================================================
-- TrackChain — Warehouse capacity, storage rent & hub routing
-- =========================================================
-- Run this once in the Supabase SQL Editor if your project already has
-- schema.sql applied. For a brand-new project just run schema.sql --
-- it already contains everything below.
--
-- WHAT THIS ADDS (four connected pieces of logic):
--
--   1. CAPACITY   Every warehouse gets a fixed, predefined capacity in
--                 units. Stock coming in can no longer exceed it -- a
--                 trigger on `inventory` rejects any change that would
--                 overflow the building.
--
--   2. RENT       Every warehouse gets a daily rent rate per stored unit,
--                 so holding stock has a running cost. The rate is DERIVED
--                 from capacity, not entered -- bulk storage costs less per
--                 unit, so a bigger hub is charged a lower rate.
--
--   3. AGING      Units that sit too long cost MORE per day. The age of
--                 stock is derived from purchase dates -- no new column
--                 records "when did this unit arrive", we reconstruct it
--                 (see warehouse_stock_age below).
--
--   4. ROUTING    When a customer orders, the system decides WHICH hub
--                 ships it -- preferring the hub holding the oldest
--                 stock, which is exactly the stock costing the most
--                 rent. So (4) exists to reduce the bill produced by (3).
--
-- Only piece 1 and 2 need to store anything; 3 and 4 are pure logic.
-- =========================================================


-- ---------------------------------------------------------
-- 1. The only new stored data: capacity. (Rent follows from it.)
-- ---------------------------------------------------------
-- Capacity is measured in UNITS, not m^3 -- `product` has no size or
-- weight attribute, so units is the only honest measure available. If
-- the model ever grows a product.volume column, only warehouse_capacity
-- below needs to change.
--
-- capacity_units has a DEFAULT so existing warehouse rows are filled in
-- automatically and nothing that already works breaks. rent_per_unit_day needs
-- no default -- it is generated from capacity, so every row gets a rate the
-- moment it has a size.

ALTER TABLE warehouse
    ADD COLUMN IF NOT EXISTS capacity_units INT NOT NULL DEFAULT 500;

-- rent_per_unit_day is DERIVED from capacity_units, never entered. Rent is a
-- property of the building in exactly the way capacity is, and the two are not
-- independent: bulk storage costs less per unit, so a bigger hub charges a
-- lower rate. That makes capacity_units -> rent_per_unit_day a functional
-- dependency, and storing a rate someone typed by hand would let the two
-- disagree -- the classic update anomaly, where enlarging a warehouse silently
-- leaves it on its old small-hub rate.
--
-- GENERATED ALWAYS ... STORED enforces it at the schema level: the column
-- cannot be inserted into or updated, and Postgres recomputes it whenever
-- capacity_units changes.
DO $$
BEGIN
    -- An earlier version of this migration created rent_per_unit_day as an
    -- ordinary, hand-set column. It cannot be converted in place, so drop it.
    -- attgenerated is '' for a normal column and 's' for a stored generated one.
    --
    -- CASCADE takes the views that read it down with it; every one of them is
    -- recreated further down this same file, so they come back immediately.
    IF EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = 'warehouse'::regclass
          AND attname  = 'rent_per_unit_day'
          AND NOT attisdropped
          AND attgenerated = ''
    ) THEN
        ALTER TABLE warehouse DROP COLUMN rent_per_unit_day CASCADE;
    END IF;
END $$;

-- The CASE is written inline rather than calling a function on purpose --
-- a generated expression must be immutable, and if it called a function whose
-- body was later edited, already-stored rates would silently drift out of step.
ALTER TABLE warehouse
    ADD COLUMN IF NOT EXISTS rent_per_unit_day NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE
            WHEN capacity_units <=  200 THEN 3.00   -- small hub, dearest per unit
            WHEN capacity_units <=  500 THEN 2.50
            WHEN capacity_units <= 1000 THEN 2.00
            ELSE                             1.50   -- bulk warehouse, cheapest
        END
    ) STORED;

-- Added separately (and idempotently) because ADD COLUMN IF NOT EXISTS
-- skips its inline CHECK when the column is already there.
--
-- Only capacity needs a CHECK now: rent is generated from it by the CASE above,
-- whose every branch is positive, so a rent constraint could never fire.
--
-- The guard checks for the CHECK by DEFINITION rather than by name. Checking
-- the name does not work: schema.sql declares this CHECK inline in CREATE
-- TABLE, so Postgres auto-names it warehouse_capacity_units_check -- a name
-- this file would never find, so it would happily add a second, redundant copy
-- on any project built from schema.sql. The lookup is also scoped with
-- conrelid, because conname is only unique per table: an unrelated table
-- carrying a same-named constraint would otherwise suppress the add.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'warehouse'::regclass
          AND contype  = 'c'
          AND pg_get_constraintdef(oid) ILIKE '%capacity_units%>%0%'
    ) THEN
        ALTER TABLE warehouse ADD CONSTRAINT warehouse_capacity_units_positive
            CHECK (capacity_units > 0);
    END IF;
END $$;


-- `warehouse.name` is used as a lookup key, not just a label: reduce_inventory()
-- (section 8) stamps the sourcing hub's name onto the shipment's 'Packed' row
-- and the order_fulfilment view joins that name back to a warehouse. Two hubs
-- sharing a name make that join ambiguous and DUPLICATE every order row it
-- produces, so make the name unique.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM warehouse GROUP BY name HAVING COUNT(*) > 1) THEN
        RAISE EXCEPTION
            'Two or more warehouses share a name. Rename the duplicates, then re-run this migration -- order_fulfilment matches hubs by name and cannot tell them apart.';
    END IF;

    -- Matched on the CONSTRAINED COLUMN, not on a name and not on rendered SQL
    -- text: schema.sql declares this one inline, where Postgres auto-names it
    -- warehouse_name_key, so a name-based test would miss it and add a second,
    -- redundant unique index.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'warehouse'::regclass
          AND contype  = 'u'
          AND conkey   = ARRAY[(SELECT attnum FROM pg_attribute
                                WHERE attrelid = 'warehouse'::regclass
                                  AND attname  = 'name')]
    ) THEN
        ALTER TABLE warehouse ADD CONSTRAINT warehouse_name_unique UNIQUE (name);
    END IF;
END $$;


-- ---------------------------------------------------------
-- 2. The aging rent model, as two tiny lookup functions.
-- ---------------------------------------------------------
-- Keeping the bands in functions (not scattered through views) means the
-- pricing policy lives in exactly one place and can be explained in one
-- breath: rent doubles on stale stock, triples on dead stock.

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


-- ---------------------------------------------------------
-- 3. How long has each unit been sitting here?
-- ---------------------------------------------------------
-- `inventory` stores a single running quantity per (warehouse, product)
-- with no arrival date, so stock age is NOT stored anywhere. We rebuild
-- it from the purchase history instead:
--
--   * every unit that ever entered a warehouse did so through a
--     purchase_item, and `purchase.purchase_date` is when it landed;
--   * assume FIFO -- the oldest units are the ones sold first;
--   * therefore the units STILL on hand are the NEWEST
--     inventory.quantity units purchased.
--
-- So we walk each (warehouse, product)'s purchase lots newest-first,
-- keeping a running total, and each lot keeps only the slice of itself
-- that falls inside the on-hand window. A lot fully consumed by past
-- sales contributes 0 units and drops out.
--
-- KNOWN LIMITATION: stock moved by the Transfer Stock feature writes
-- straight to `inventory` with no purchase lot in the destination, so
-- those units have no reconstructable arrival date. They are billed at
-- the plain 1.0x rate rather than being silently dropped -- see the
-- "billable_units" comment in warehouse_rent below.

CREATE OR REPLACE VIEW warehouse_stock_age AS
WITH lots AS (
    SELECT
        p.warehouse_id,
        pi.product_id,
        p.purchase_date,
        pi.quantity,
        SUM(pi.quantity) OVER (
            PARTITION BY p.warehouse_id, pi.product_id
            ORDER BY p.purchase_date DESC, pi.purchase_item_id DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cum_newest_first
    FROM purchase_item pi
    JOIN purchase p ON p.purchase_id = pi.purchase_id
),
remaining AS (
    SELECT
        l.warehouse_id,
        l.product_id,
        l.purchase_date,
        -- How much of this lot survives inside the newest-N-units window.
        LEAST(l.quantity, GREATEST(i.quantity - (l.cum_newest_first - l.quantity), 0))::INT AS units,
        GREATEST(EXTRACT(DAY FROM NOW() - l.purchase_date)::INT, 0) AS days_stored
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
    r.purchase_date AS received_date,
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
-- 4. Capacity: how full is each warehouse right now?
-- ---------------------------------------------------------
-- Capacity itself never changes when stock arrives -- it is a property
-- of the building. What changes is used_units / free_units, so this view
-- is the answer to "if inventory increases, what happens to capacity".

CREATE OR REPLACE VIEW warehouse_capacity AS
SELECT
    w.warehouse_id,
    w.name,
    w.location,
    w.capacity_units,
    COALESCE(SUM(i.quantity), 0)::INT                         AS used_units,
    (w.capacity_units - COALESCE(SUM(i.quantity), 0))::INT    AS free_units,
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


-- ---------------------------------------------------------
-- 5. Rent: what does holding this stock cost per day?
-- ---------------------------------------------------------
-- base_daily_rent      = every unit at the plain rate (what rent WOULD
--                        be if nothing had gone stale)
-- surcharge_daily_rent = the extra caused purely by slow-moving stock
-- total_daily_rent     = what you actually pay

CREATE OR REPLACE VIEW warehouse_rent AS
WITH onhand AS (
    SELECT warehouse_id, COALESCE(SUM(quantity), 0)::INT AS units
    FROM inventory
    GROUP BY warehouse_id
),
aged AS (
    SELECT
        warehouse_id,
        SUM(units)::INT                AS lot_units,
        SUM(units * rent_multiplier)   AS weighted_units,
        SUM(CASE WHEN days_stored > 30 THEN units ELSE 0 END)::INT AS overdue_units,
        MAX(days_stored)::INT          AS oldest_days
    FROM warehouse_stock_age
    GROUP BY warehouse_id
),
billing AS (
    SELECT
        w.warehouse_id,
        w.name,
        w.rent_per_unit_day,
        COALESCE(o.units, 0)          AS on_hand_units,
        COALESCE(a.overdue_units, 0)  AS overdue_units,
        COALESCE(a.oldest_days, 0)    AS oldest_days,
        -- Units billed at their own aged rate, PLUS any on-hand units with
        -- no purchase lot in this warehouse (they arrived via a transfer, so
        -- their age is unknown) billed at the plain 1.0x rate. Adding that
        -- remainder keeps the rent bill consistent with on_hand_units
        -- instead of quietly under-billing transferred stock.
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


-- One flat row per warehouse with capacity AND rent side by side --
-- this is what the Warehouse page reads so it needs a single request.
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


-- ---------------------------------------------------------
-- 6. Enforcement: a warehouse cannot be overfilled.
-- ---------------------------------------------------------
-- Guarding `inventory` rather than `purchase_item` is deliberate: EVERY
-- route that adds stock ends up writing here -- purchases (through
-- increase_inventory) and the Transfer Stock screen (which updates
-- inventory directly). One trigger therefore closes both doors; a
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

DROP TRIGGER IF EXISTS trg_enforce_warehouse_capacity ON inventory;
CREATE TRIGGER trg_enforce_warehouse_capacity
BEFORE INSERT OR UPDATE ON inventory
FOR EACH ROW EXECUTE FUNCTION enforce_warehouse_capacity();


-- The other way to break capacity is to shrink the building instead of
-- growing the stock, so block that too.
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

DROP TRIGGER IF EXISTS trg_check_capacity_not_below_stock ON warehouse;
CREATE TRIGGER trg_check_capacity_not_below_stock
BEFORE UPDATE ON warehouse
FOR EACH ROW EXECUTE FUNCTION check_capacity_not_below_stock();


-- ---------------------------------------------------------
-- 7. Routing: which hub does a customer order ship from?
-- ---------------------------------------------------------
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
-- Returns NULL when no single hub can cover the quantity -- splitting one
-- order line across two hubs is out of scope (it would need a per-item
-- fulfilment record, i.e. a new table).

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


-- Same ranking, but showing EVERY candidate hub and flagging the winner.
-- The Warehouse page uses this so a user can see why a hub was picked
-- instead of just being told which one.
-- Dropped first because the surcharge_units column below changes the return
-- type, and CREATE OR REPLACE FUNCTION cannot do that.
DROP FUNCTION IF EXISTS hub_routing_preview(INT, INT);

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


-- ---------------------------------------------------------
-- 8. Rewire the sales side to actually USE the chosen hub.
-- ---------------------------------------------------------
-- The original reduce_inventory() did:
--     SELECT quantity FROM inventory WHERE product_id = X LIMIT 1
-- with no warehouse filter and no ORDER BY, so it checked and then
-- deducted from an ARBITRARY warehouse -- and could even fail a
-- perfectly fillable order because the row it happened to pick was the
-- empty one. This version asks pick_source_warehouse() first and
-- deducts from that hub specifically.
--
-- It also RECORDS the decision, with no new column: shipment_status
-- already has a `location` field, and the auto-created 'Packed' row left
-- it NULL. Writing the hub name there makes "which hub did this order
-- ship from" a permanent, queryable fact (see the order_fulfilment view).

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

    -- Stamp the sourcing hub onto the shipment's initial 'Packed' status.
    -- A multi-item order whose lines come from different hubs is marked
    -- 'Multiple hubs' rather than pretending a single origin.
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

DROP TRIGGER IF EXISTS trg_reduce_inventory ON order_item;
CREATE TRIGGER trg_reduce_inventory
AFTER INSERT ON order_item
FOR EACH ROW EXECUTE FUNCTION reduce_inventory();


-- Every order with the hub it shipped from, read back out of
-- shipment_status. source_warehouse_id is matched on NAME because no FK
-- is possible without adding a column -- acceptable here since
-- warehouse.name is what reduce_inventory() wrote, and it is the price of
-- keeping the table structure untouched.
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
-- END OF MIGRATION
-- =========================================================
-- Suggested capacities (optional). The column DEFAULT already gave every
-- existing warehouse 500 units, which lands them all in the 2.50/unit/day band
-- -- and at 500 units nothing is likely to look full, so the capacity warning
-- stays invisible. Tightening one hub makes it show.
--
-- Set ONLY capacity. rent_per_unit_day is a generated column, so naming it in
-- an UPDATE raises "column can only be updated to DEFAULT" -- the rate follows
-- from the capacity you set here.
--
-- UPDATE warehouse SET capacity_units = 400 WHERE name = 'Dhaka Hub';        -- -> 2.50/unit/day
-- UPDATE warehouse SET capacity_units = 150 WHERE name = 'Chittagong Hub';   -- -> 3.00/unit/day
--
-- Check what the bands gave you:
--   SELECT name, capacity_units, rent_per_unit_day FROM warehouse ORDER BY capacity_units DESC;
