-- =========================================================
-- Migration: Row Level Security for the business tables
-- =========================================================
-- DEPENDS ON: `staff_profiles` and `current_staff_role()` already existing
-- in the database -- created by database/migration_add_staff_auth.sql
-- (already on main, commit f33e842). This migration does NOT create or
-- redefine either of those -- it only USES the existing
-- current_staff_role() inside new policies. Do not re-run
-- migration_add_staff_auth.sql's `CREATE TABLE staff_profiles` or
-- `CREATE OR REPLACE FUNCTION current_staff_role()` after this one; that
-- would silently overwrite the live version and is exactly the
-- duplication this file is written to avoid.
--
-- What staff_profiles + current_staff_role() already give us:
--   - Real Supabase Auth accounts (real email + hashed password)
--   - staff_profiles(id, email, full_name, role, is_active, ...)
--   - current_staff_role() -- STABLE, SECURITY DEFINER, returns the
--     caller's role (one of admin/purchasing/marketing/warehouse/shipment)
--     if they're an active staff member, else NULL
--   - Staff account management (add/change role/deactivate) via the
--     admin-manage-staff Edge Function, not exposed through RLS writes
--
-- What was still missing, and what THIS file adds: the 17 business
-- tables (supplier, product, order, etc. -- schema.sql Section 11
-- currently leaves them fully open to the anon key) have no row-level
-- protection at all yet. Being logged in as "marketing" today changes
-- what the UI *shows* you, but nothing stops a direct API call from
-- writing to any table regardless of role. This migration closes that
-- gap using the SAME two-tier model already agreed for this project:
--
--   SELECT is staff-wide: any active staff member, of ANY role, can read
--   every internal table -- required because pages like Orders (visible
--   to "shipment") still join in product/customer names even though those
--   modules aren't in that role's own allowed pages. audit_log is the one
--   exception -- SELECT is admin-only.
--
--   INSERT/UPDATE/DELETE is role-scoped, matching exactly which
--   page/role performs that write today (confirmed by grepping every
--   .insert()/.update()/.delete() call across frontend/**/*.html).
--
--   The public storefront (no login) keeps working via narrow anon
--   policies scoped to exactly what frontend/storefront/*.html reads or
--   writes directly.
--
--   place_order_api / place_purchase_api / transfer_stock_api become
--   SECURITY DEFINER (so they can still write across tables despite RLS),
--   with an explicit current_staff_role() check now added INSIDE the two
--   staff-only ones, since that in-function check is the only protection
--   left once a function bypasses RLS. Trigger functions that cascade a
--   write to a DIFFERENT table (audit logging, inventory adjustment,
--   auto-shipment-creation) also become SECURITY DEFINER, so those
--   system-maintained side effects keep working no matter which role's
--   direct action fired them.
-- =========================================================


-- =========================================================
-- SECTION A: ENABLE ROW LEVEL SECURITY ON EVERY BUSINESS TABLE
-- =========================================================

ALTER TABLE supplier          ENABLE ROW LEVEL SECURITY;
ALTER TABLE product           ENABLE ROW LEVEL SECURITY;
ALTER TABLE warehouse         ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory         ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfer    ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer          ENABLE ROW LEVEL SECURITY;
ALTER TABLE "order"           ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_item        ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign          ENABLE ROW LEVEL SECURITY;
ALTER TABLE tracking_link     ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_attribution ENABLE ROW LEVEL SECURITY;
ALTER TABLE click             ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipment          ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipment_status   ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase          ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_item     ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log         ENABLE ROW LEVEL SECURITY;


-- =========================================================
-- SECTION B: STAFF-WIDE READ ACCESS
-- =========================================================

CREATE POLICY staff_select_all ON supplier          FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON product            FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON warehouse           FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON inventory           FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON stock_transfer      FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON customer            FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON "order"             FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON order_item          FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON campaign            FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON tracking_link       FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON order_attribution   FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON click               FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON shipment            FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON shipment_status     FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON purchase            FOR SELECT USING (current_staff_role() IS NOT NULL);
CREATE POLICY staff_select_all ON purchase_item       FOR SELECT USING (current_staff_role() IS NOT NULL);

-- audit_log is the one exception: only admin can read it.
CREATE POLICY admin_select_audit_log ON audit_log
    FOR SELECT USING (current_staff_role() = 'admin');


-- =========================================================
-- SECTION C: PUBLIC STOREFRONT (no login) READ + WRITE ACCESS
-- =========================================================
-- Scoped to exactly what frontend/storefront/*.html reads/writes today.

-- product.html: browse the catalog + see stock
CREATE POLICY anon_select_product   ON product   FOR SELECT TO anon USING (true);
CREATE POLICY anon_select_inventory ON inventory FOR SELECT TO anon USING (true);

-- redirect.html: resolve a tracking link, log a click
CREATE POLICY anon_select_tracking_link ON tracking_link FOR SELECT TO anon USING (true);
CREATE POLICY anon_select_campaign      ON campaign      FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert_click         ON click         FOR INSERT TO anon WITH CHECK (true);

-- product.html guest checkout: look up or create a customer by phone
CREATE POLICY anon_select_customer ON customer FOR SELECT TO anon USING (true);
CREATE POLICY anon_insert_customer ON customer FOR INSERT TO anon WITH CHECK (true);

-- track.html: look up a shipment by its TRK code
CREATE POLICY anon_select_shipment        ON shipment        FOR SELECT TO anon USING (true);
CREATE POLICY anon_select_shipment_status ON shipment_status FOR SELECT TO anon USING (true);


-- =========================================================
-- SECTION D: ROLE-SCOPED WRITE ACCESS (the actual access control)
-- =========================================================
-- | Table                        | Direct write from                  | Roles allowed        |
-- |-------------------------------|------------------------------------|----------------------|
-- | supplier                      | suppliers/index.html               | purchasing, admin    |
-- | product                       | suppliers/, products/index.html    | purchasing, warehouse, admin |
-- | warehouse                     | warehouses/index.html              | warehouse, admin     |
-- | customer (staff side)         | customers/index.html               | marketing, admin     |
-- | purchase (delete only)        | purchases/index.html               | purchasing, admin    |
-- | shipment_status (insert only) | shipments/index.html               | shipment, admin      |
-- | campaign, tracking_link       | campaigns/index.html                | marketing, admin     |
-- stock_transfer / "order" / order_item / purchase_item / inventory /
-- audit_log get NO client-facing write policy here on purpose -- every
-- write to those happens only through the SECURITY DEFINER functions and
-- triggers in Section E/F, which bypass RLS for their own internal writes.

CREATE POLICY role_write_supplier ON supplier
    FOR ALL
    USING       (current_staff_role() IN ('purchasing','admin'))
    WITH CHECK  (current_staff_role() IN ('purchasing','admin'));

CREATE POLICY role_write_product ON product
    FOR ALL
    USING       (current_staff_role() IN ('purchasing','warehouse','admin'))
    WITH CHECK  (current_staff_role() IN ('purchasing','warehouse','admin'));

CREATE POLICY role_write_warehouse ON warehouse
    FOR ALL
    USING       (current_staff_role() IN ('warehouse','admin'))
    WITH CHECK  (current_staff_role() IN ('warehouse','admin'));

CREATE POLICY role_write_customer ON customer
    FOR ALL
    USING       (current_staff_role() IN ('marketing','admin'))
    WITH CHECK  (current_staff_role() IN ('marketing','admin'));

CREATE POLICY role_delete_purchase ON purchase
    FOR DELETE
    USING (current_staff_role() IN ('purchasing','admin'));

CREATE POLICY role_insert_shipment_status ON shipment_status
    FOR INSERT
    WITH CHECK (current_staff_role() IN ('shipment','admin'));

CREATE POLICY role_write_campaign ON campaign
    FOR ALL
    USING       (current_staff_role() IN ('marketing','admin'))
    WITH CHECK  (current_staff_role() IN ('marketing','admin'));

CREATE POLICY role_write_tracking_link ON tracking_link
    FOR ALL
    USING       (current_staff_role() IN ('marketing','admin'))
    WITH CHECK  (current_staff_role() IN ('marketing','admin'));


-- =========================================================
-- SECTION E: SECURITY DEFINER -- RPCs that must bypass RLS, with their
-- own explicit role checks now that RLS itself can no longer protect them
-- =========================================================

-- Public guest-checkout path: intentionally open to anon AND staff, so no
-- role check is added here -- only SECURITY DEFINER, to let it write
-- "order" / order_item / order_attribution despite RLS.
CREATE OR REPLACE FUNCTION place_order_api(
    p_customer_id INT,
    p_tracking_link_id INT,
    p_product_id INT,
    p_quantity INT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- Staff-only: Purchasing Officers + Admin. The IF check below is now the
-- ONLY thing stopping e.g. a Marketing account from calling this directly.
CREATE OR REPLACE FUNCTION place_purchase_api(
    p_supplier_id INT,
    p_warehouse_id INT,
    p_product_id INT,
    p_quantity INT,
    p_unit_cost NUMERIC
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_purchase_id INT;
BEGIN
    IF current_staff_role() NOT IN ('purchasing','admin') THEN
        RAISE EXCEPTION 'Only Purchasing Officers or Admins can record a purchase';
    END IF;

    INSERT INTO purchase(supplier_id, warehouse_id)
    VALUES (p_supplier_id, p_warehouse_id)
    RETURNING purchase_id INTO v_purchase_id;

    INSERT INTO purchase_item(purchase_id, product_id, quantity, unit_cost)
    VALUES (v_purchase_id, p_product_id, p_quantity, p_unit_cost);

    RETURN v_purchase_id;
END;
$$;

-- Staff-only: Warehouse Managers + Admin.
CREATE OR REPLACE FUNCTION transfer_stock_api(
    p_product_id        INT,
    p_from_warehouse_id INT,
    p_to_warehouse_id   INT,
    p_quantity          INT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_source_qty INT;
    v_remaining  INT := p_quantity;
    v_take       INT;
    lot          RECORD;
BEGIN
    IF current_staff_role() NOT IN ('warehouse','admin') THEN
        RAISE EXCEPTION 'Only Warehouse Managers or Admins can transfer stock';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Transfer quantity must be greater than zero';
    END IF;

    IF p_from_warehouse_id = p_to_warehouse_id THEN
        RAISE EXCEPTION 'Source and destination hub must be different';
    END IF;

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

    IF v_remaining > 0 THEN
        INSERT INTO stock_transfer(from_warehouse_id, to_warehouse_id, product_id, quantity, origin_date)
        VALUES (p_from_warehouse_id, p_to_warehouse_id, p_product_id, v_remaining, NOW());
    END IF;

    UPDATE inventory
    SET quantity = quantity - p_quantity
    WHERE warehouse_id = p_from_warehouse_id AND product_id = p_product_id;

    INSERT INTO inventory(warehouse_id, product_id, quantity)
    VALUES (p_to_warehouse_id, p_product_id, p_quantity)
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity = inventory.quantity + EXCLUDED.quantity;

    RETURN p_quantity;
END;
$$;


-- =========================================================
-- SECTION F: SECURITY DEFINER -- trigger functions that cascade a write to
-- a DIFFERENT table than the one the client directly touched. Without
-- this, e.g. a direct client DELETE on `purchase` (purchases/index.html,
-- not wrapped in an RPC) would fire log_audit_purchase, whose own INSERT
-- INTO audit_log would then be blocked by audit_log's admin-only policy.
-- =========================================================

CREATE OR REPLACE FUNCTION log_audit_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('order', TG_OP, OLD.order_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('order', TG_OP, NEW.order_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION log_audit_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('inventory', TG_OP, OLD.inventory_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('inventory', TG_OP, NEW.inventory_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION log_audit_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('purchase', TG_OP, OLD.purchase_id);
        RETURN OLD;
    ELSE
        INSERT INTO audit_log(table_name, operation, record_id) VALUES ('purchase', TG_OP, NEW.purchase_id);
        RETURN NEW;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION reduce_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
            RAISE EXCEPTION 'Insufficient stock for product_id % (need %, only % across all hubs)',
                NEW.product_id, NEW.quantity, v_total_available;
        ELSE
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
$$;

CREATE OR REPLACE FUNCTION increase_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

CREATE OR REPLACE FUNCTION reverse_inventory_on_purchase_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

CREATE OR REPLACE FUNCTION create_shipment_for_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;
