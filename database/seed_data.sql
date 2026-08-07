-- =========================================================
-- TrackChain Seed Data
-- Run this AFTER schema.sql, in the same SQL Editor.
-- Gives every dashboard/view real, non-empty numbers to show.
-- =========================================================

-- ---------- Suppliers & Products ----------
INSERT INTO supplier (name, phone, address) VALUES
('TechSource Ltd', '01711000001', 'Mirpur, Dhaka'),
('Global Textiles', '01711000002', 'Gazipur, Dhaka'),
('HomeEssentials Co', '01711000003', 'Narayanganj');

INSERT INTO product (supplier_id, name, category, price) VALUES
(1, 'Wireless Earbuds X200', 'Electronics', 1899.00),
(1, 'Smartwatch Lite',       'Electronics', 3499.00),
(2, 'Cotton T-Shirt',        'Apparel',      499.00),
(2, 'Denim Jacket',          'Apparel',     1899.00),
(3, 'Non-stick Pan Set',     'Kitchen',     1299.00),
(3, 'Table Lamp',            'Home',         899.00);

-- ---------- Warehouses ----------
-- Only capacity is set. rent_per_unit_day is a GENERATED column derived from
-- it, so it cannot be inserted -- Postgres fills it in from the size bands:
--
--   Dhaka       400 units -> 2.50 /unit/day
--   Chittagong  150 units -> 3.00 /unit/day   (small hub, dearest per unit)
--
-- Chittagong being the SMALLER hub is what makes it the expensive one to hold
-- stock in: bulk storage is cheaper per unit. It also ends up ~83% full after
-- the purchases below, so the capacity warning is visible in the UI without
-- anything failing. Try pushing another 30 units into it to see
-- trg_enforce_warehouse_capacity reject the write.
INSERT INTO warehouse (name, location, capacity_units) VALUES
('Dhaka Hub', 'Tejgaon, Dhaka', 400),
('Chittagong Hub', 'Agrabad, Chittagong', 150);

-- ---------- Purchases ----------
-- Inventory should never "magically" appear -- every unit of opening
-- stock is recorded as a purchase from the product's own supplier into a
-- warehouse. Each CALL fires trg_increase_inventory automatically, so
-- the resulting stock levels are identical to the old hardcoded
-- INSERT INTO inventory this replaces, but now with full provenance.
CALL place_purchase(1, 1, 1, 40,  1100.00);  -- TechSource -> Dhaka Hub -> Earbuds x40
CALL place_purchase(1, 1, 2, 25,  2000.00);  -- TechSource -> Dhaka Hub -> Smartwatch x25
CALL place_purchase(2, 1, 3, 100, 250.00);   -- Global Textiles -> Dhaka Hub -> T-Shirt x100
CALL place_purchase(2, 1, 4, 30,  1000.00);  -- Global Textiles -> Dhaka Hub -> Denim Jacket x30
CALL place_purchase(3, 1, 5, 8,   700.00);   -- HomeEssentials -> Dhaka Hub -> Pan Set x8
CALL place_purchase(3, 1, 6, 15,  450.00);   -- HomeEssentials -> Dhaka Hub -> Table Lamp x15
CALL place_purchase(1, 2, 1, 20,  1100.00);  -- TechSource -> Chittagong Hub -> Earbuds x20
CALL place_purchase(1, 2, 2, 10,  2000.00);  -- TechSource -> Chittagong Hub -> Smartwatch x10
CALL place_purchase(2, 2, 3, 60,  250.00);   -- Global Textiles -> Chittagong Hub -> T-Shirt x60
CALL place_purchase(2, 2, 4, 12,  1000.00);  -- Global Textiles -> Chittagong Hub -> Denim Jacket x12
CALL place_purchase(3, 2, 5, 5,   700.00);   -- HomeEssentials -> Chittagong Hub -> Pan Set x5
CALL place_purchase(3, 2, 6, 20,  450.00);   -- HomeEssentials -> Chittagong Hub -> Table Lamp x20

-- ---------- Backdate a few purchases so stock has a realistic age spread ----------
-- warehouse_stock_age derives how long stock has been sitting from
-- purchase.purchase_date, so with every purchase landing "now" the whole
-- warehouse would look Fresh and both the rent surcharge and the
-- oldest-stock-first routing rule would have nothing to show. Backdating
-- five of the twelve purchases puts stock in all four age bands.
--
-- Matched on warehouse + product rather than purchase_id, because each
-- CALL place_purchase above creates exactly one purchase with one item --
-- so this stays correct even if the ids shift.
UPDATE purchase p SET purchase_date = NOW() - INTERVAL '95 day'
WHERE p.warehouse_id = 1 AND EXISTS (SELECT 1 FROM purchase_item pi WHERE pi.purchase_id = p.purchase_id AND pi.product_id = 4);   -- Dhaka Denim Jacket -> Dead stock (3.0x)
UPDATE purchase p SET purchase_date = NOW() - INTERVAL '72 day'
WHERE p.warehouse_id = 1 AND EXISTS (SELECT 1 FROM purchase_item pi WHERE pi.purchase_id = p.purchase_id AND pi.product_id = 5);   -- Dhaka Pan Set     -> Stale (2.0x)
UPDATE purchase p SET purchase_date = NOW() - INTERVAL '45 day'
WHERE p.warehouse_id = 1 AND EXISTS (SELECT 1 FROM purchase_item pi WHERE pi.purchase_id = p.purchase_id AND pi.product_id = 6);   -- Dhaka Table Lamp  -> Aging (1.5x)
UPDATE purchase p SET purchase_date = NOW() - INTERVAL '105 day'
WHERE p.warehouse_id = 2 AND EXISTS (SELECT 1 FROM purchase_item pi WHERE pi.purchase_id = p.purchase_id AND pi.product_id = 1);   -- Chittagong Earbuds -> Dead stock (3.0x)
UPDATE purchase p SET purchase_date = NOW() - INTERVAL '38 day'
WHERE p.warehouse_id = 2 AND EXISTS (SELECT 1 FROM purchase_item pi WHERE pi.purchase_id = p.purchase_id AND pi.product_id = 4);   -- Chittagong Denim   -> Aging (1.5x)


-- ---------- Customers ----------
INSERT INTO customer (name, contact) VALUES
('Ariful Islam',  '01911000001'),
('Nusrat Jahan',  '01911000002'),
('Rakib Hasan',   '01911000003'),
('Sadia Afrin',   '01911000004'),
('Tanvir Ahmed',  '01911000005');

-- ---------- Campaigns ----------
INSERT INTO campaign (product_id, campaign_name, start_date, end_date) VALUES
(1, 'Earbuds Summer Push',   '2026-06-01', '2026-06-30'),
(3, 'T-Shirt Flash Sale',    '2026-07-01', '2026-07-15'),
(5, 'Kitchen Combo Offer',   '2026-07-10', '2026-07-25');

-- ---------- Tracking links (platform prefix + campaign id) ----------
INSERT INTO tracking_link (campaign_id, platform, short_code, destination_url) VALUES
(1, 'Facebook', 'FB1', 'https://trackchain.example/product/1'),
(1, 'Instagram','IG1', 'https://trackchain.example/product/1'),
(1, 'Email',    'EM1', 'https://trackchain.example/product/1'),
(2, 'Facebook', 'FB2', 'https://trackchain.example/product/3'),
(2, 'WhatsApp', 'WA2', 'https://trackchain.example/product/3'),
(3, 'Instagram','IG3', 'https://trackchain.example/product/5'),
(3, 'Email',    'EM3', 'https://trackchain.example/product/5');

-- ---------- Clicks (anonymous for social platforms, known for Email) ----------
INSERT INTO click (link_id, click_time, country, device, customer_id) VALUES
(1, NOW() - INTERVAL '5 day', 'Bangladesh', 'Android', NULL),
(1, NOW() - INTERVAL '4 day', 'Bangladesh', 'iOS', NULL),
(1, NOW() - INTERVAL '3 day', 'India', 'Android', NULL),
(2, NOW() - INTERVAL '5 day', 'Bangladesh', 'iOS', NULL),
(2, NOW() - INTERVAL '2 day', 'Bangladesh', 'Android', NULL),
(3, NOW() - INTERVAL '6 day', 'Bangladesh', 'Desktop', 1),
(3, NOW() - INTERVAL '1 day', 'Bangladesh', 'Desktop', 2),
(4, NOW() - INTERVAL '4 day', 'Bangladesh', 'Android', NULL),
(4, NOW() - INTERVAL '3 day', 'Bangladesh', 'Android', NULL),
(4, NOW() - INTERVAL '2 day', 'UAE', 'iOS', NULL),
(5, NOW() - INTERVAL '3 day', 'Bangladesh', 'Android', NULL),
(6, NOW() - INTERVAL '2 day', 'Bangladesh', 'iOS', NULL),
(7, NOW() - INTERVAL '2 day', 'Bangladesh', 'Desktop', 3),
(7, NOW() - INTERVAL '1 day', 'Bangladesh', 'Desktop', 4);

-- ---------- Orders (via the tested procedure -- this also fires the
-- inventory-reduction trigger automatically for each one) ----------
-- reduce_inventory() now routes each line through pick_source_warehouse(),
-- which ships from whichever hub holds the OLDEST stock of that product, and
-- records the winner on the shipment's 'Packed' status row. Because of the
-- backdating above the first two orders leave from Chittagong even though
-- Dhaka holds twice as many earbuds -- Chittagong's are 105 days old and
-- costing 3x rent, so clearing them first is the point. Check afterwards
-- with:  SELECT order_id, source_hub FROM order_fulfilment ORDER BY order_id;
CALL place_order(1, 3, 1, 2);   -- Ariful buys 2x Earbuds via Email campaign  -> Chittagong (105d stock)
CALL place_order(2, 1, 1, 1);   -- Nusrat buys 1x Earbuds via Facebook        -> Chittagong (105d stock)
CALL place_order(3, 4, 3, 3);   -- Rakib buys 3x T-Shirt via Facebook         -> Dhaka (both fresh, Dhaka has more)
CALL place_order(4, 5, 3, 1);   -- Sadia buys 1x T-Shirt via WhatsApp         -> Dhaka (both fresh, Dhaka has more)
CALL place_order(5, 7, 5, 2);   -- Tanvir buys 2x Pan Set via Email           -> Dhaka (72d stock)
CALL place_order(1, 6, 5, 1);   -- Ariful buys 1x Pan Set via Instagram       -> Dhaka (72d stock)

-- ---------- Shipments ----------
-- trg_create_shipment_on_order already auto-created one shipment per order
-- above (each CALL place_order(...) fired it), each starting out with a
-- single 'Packed' status row dated "now". We only backdate those here so
-- the demo tells a realistic multi-day story -- in real usage nothing
-- ever touches shipment/shipment_status by hand like this.

UPDATE shipment SET shipment_date = NOW() - INTERVAL '4 day' WHERE order_id = 1;
UPDATE shipment SET shipment_date = NOW() - INTERVAL '3 day' WHERE order_id = 2;
UPDATE shipment SET shipment_date = NOW() - INTERVAL '2 day' WHERE order_id = 3;
UPDATE shipment SET shipment_date = NOW() - INTERVAL '1 day' WHERE order_id = 4;
-- Orders 5 and 6 keep today's shipment_date -- freshly packed.

UPDATE shipment_status ss SET updated_time = NOW() - INTERVAL '4 day'
FROM shipment s WHERE s.shipment_id = ss.shipment_id AND s.order_id = 1 AND ss.status = 'Packed';
UPDATE shipment_status ss SET updated_time = NOW() - INTERVAL '3 day'
FROM shipment s WHERE s.shipment_id = ss.shipment_id AND s.order_id = 2 AND ss.status = 'Packed';
UPDATE shipment_status ss SET updated_time = NOW() - INTERVAL '2 day'
FROM shipment s WHERE s.shipment_id = ss.shipment_id AND s.order_id = 3 AND ss.status = 'Packed';
UPDATE shipment_status ss SET updated_time = NOW() - INTERVAL '1 day'
FROM shipment s WHERE s.shipment_id = ss.shipment_id AND s.order_id = 4 AND ss.status = 'Packed';

-- ---------- Shipment status progression (beyond the auto-created 'Packed') ----------
-- Order 1 goes all the way to Delivered; orders 2-6 are intentionally left
-- short of 'Delivered', so pending_shipment_report() has something to show.
-- The 'In Transit' rows read their location back off the 'Packed' row rather
-- than hardcoding a hub name, so they always agree with whichever hub
-- pick_source_warehouse() actually chose for the order.
INSERT INTO shipment_status (shipment_id, location, status, updated_time)
SELECT s.shipment_id, packed.location, 'In Transit', NOW() - INTERVAL '3 day'
FROM shipment s
JOIN shipment_status packed ON packed.shipment_id = s.shipment_id AND packed.status = 'Packed'
WHERE s.order_id = 1
UNION ALL
SELECT s.shipment_id, 'Customer Area', 'Out For Delivery', NOW() - INTERVAL '2 day' FROM shipment s WHERE s.order_id = 1
UNION ALL
SELECT s.shipment_id, 'Customer Area', 'Delivered', NOW() - INTERVAL '1 day' FROM shipment s WHERE s.order_id = 1
UNION ALL
SELECT s.shipment_id, packed.location, 'In Transit', NOW() - INTERVAL '2 day'
FROM shipment s
JOIN shipment_status packed ON packed.shipment_id = s.shipment_id AND packed.status = 'Packed'
WHERE s.order_id = 2;


