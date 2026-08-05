-- =========================================================
-- Run this once in the Supabase SQL Editor if your project already has
-- schema.sql (with the original purchase/purchase_item tables) applied.
-- For a brand-new project, just run the full schema.sql instead -- it
-- already includes both fixes below.
-- =========================================================

---- Reject a purchase_item whose product isn't supplied by the purchase's supplier ----
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

DROP TRIGGER IF EXISTS trg_check_purchase_supplier_match ON purchase_item;
CREATE TRIGGER trg_check_purchase_supplier_match
BEFORE INSERT ON purchase_item
FOR EACH ROW EXECUTE FUNCTION check_purchase_supplier_match();

---- Reverse the inventory increase when a purchase is deleted ----
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

DROP TRIGGER IF EXISTS trg_reverse_inventory_on_purchase_delete ON purchase;
CREATE TRIGGER trg_reverse_inventory_on_purchase_delete
BEFORE DELETE ON purchase
FOR EACH ROW EXECUTE FUNCTION reverse_inventory_on_purchase_delete();


