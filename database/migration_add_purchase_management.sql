-- =========================================================
-- Migration: add Purchase Management to an EXISTING database
-- =========================================================
-- Run this once in the Supabase SQL Editor if your project already has
-- schema.sql applied (so CREATE TABLE supplier/product/etc. would fail
-- if you re-ran the whole file). This block only adds what's new:
-- purchase/purchase_item tables, the increase-inventory trigger, the
-- place_purchase procedure/function, the purchase_history view, and RLS.
--
-- For a brand-new project, just run the full schema.sql instead -- it
-- already includes all of this.
-- =========================================================

-- ---- Tables ----
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

-- ---- Audit trigger ----
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

-- ---- Increase-inventory trigger (mirror of reduce_inventory, but upserts) ----
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

-- ---- Procedure (viva/SQL Editor) + function (frontend RPC) ----
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

-- ---- Report view ----
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

-- ---- Access for the frontend (same demo-only tradeoff as the rest of the schema) ----
ALTER TABLE purchase      DISABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_item DISABLE ROW LEVEL SECURITY;
