-- =========================================================
-- SupplySphere Database Schema
-- Integrated Supply Chain & Campaign Analytics System
-- =========================================================
-- HOW TO USE:
-- 1. Create a Supabase project (or any Postgres instance)
-- 2. Open the SQL editor and run this file top to bottom
-- 3. Everything below is commented so your team can explain
--    every line at the viva.
-- =========================================================


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

CREATE TABLE warehouse (
    warehouse_id SERIAL PRIMARY KEY,
    name         VARCHAR(100) NOT NULL,
    location     VARCHAR(150)
);

CREATE TABLE inventory (
    inventory_id SERIAL PRIMARY KEY,
    warehouse_id INT NOT NULL REFERENCES warehouse(warehouse_id),
    product_id   INT NOT NULL REFERENCES product(product_id),
    quantity     INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    UNIQUE (warehouse_id, product_id)  -- one row per product per warehouse
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
-- Inventory should never "magically" increase -- every stock increment
-- must be traceable to a purchase from a supplier into a warehouse.
-- This mirrors order/order_item exactly, just for the inbound side.

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

-- (Your team can add trg_audit_shipment, trg_audit_customer the same way
--  if you want more tables audited -- copy-paste-adapt the pattern above.
--  Auditing every one of the 13 tables is not necessary; 3-4 well-chosen
--  ones is enough to demonstrate the concept.)


-- 6.2 Business-logic trigger: reduce inventory automatically
-- whenever an order_item is inserted. This is the trigger you'll
-- most want to explain in the viva -- it enforces a real business rule.
CREATE OR REPLACE FUNCTION reduce_inventory()
RETURNS TRIGGER AS $$
DECLARE
    available INT;
BEGIN
    SELECT quantity INTO available
    FROM inventory
    WHERE product_id = NEW.product_id
    LIMIT 1;

    IF available IS NULL THEN
        RAISE EXCEPTION 'No inventory record found for product_id %', NEW.product_id;
    ELSIF available < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product_id % (have %, need %)',
            NEW.product_id, available, NEW.quantity;
    END IF;

    UPDATE inventory
    SET quantity = quantity - NEW.quantity
    WHERE product_id = NEW.product_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reduce_inventory
AFTER INSERT ON order_item
FOR EACH ROW EXECUTE FUNCTION reduce_inventory();


-- 6.2b Mirror image of reduce_inventory(): increase inventory whenever a
-- purchase_item is inserted. Unlike the sales side, this one *upserts* --
-- a purchase can be the first time a product is ever stocked at a given
-- warehouse, so there may not be an inventory row yet to update.
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
