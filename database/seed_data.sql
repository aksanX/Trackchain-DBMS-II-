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
INSERT INTO warehouse (name, location) VALUES
('Dhaka Hub', 'Tejgaon, Dhaka'),
('Chittagong Hub', 'Agrabad, Chittagong');

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
CALL place_order(1, 3, 1, 2);   -- Ariful buys 2x Earbuds via Email campaign
CALL place_order(2, 1, 1, 1);   -- Nusrat buys 1x Earbuds via Facebook
CALL place_order(3, 4, 3, 3);   -- Rakib buys 3x T-Shirt via Facebook
CALL place_order(4, 5, 3, 1);   -- Sadia buys 1x T-Shirt via WhatsApp
CALL place_order(5, 7, 5, 2);   -- Tanvir buys 2x Pan Set via Email
CALL place_order(1, 6, 5, 1);   -- Ariful buys 1x Pan Set via Instagram

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
INSERT INTO shipment_status (shipment_id, location, status, updated_time)
SELECT shipment_id, 'Dhaka Hub', 'In Transit', NOW() - INTERVAL '3 day' FROM shipment WHERE order_id = 1
UNION ALL
SELECT shipment_id, 'Customer Area', 'Out For Delivery', NOW() - INTERVAL '2 day' FROM shipment WHERE order_id = 1
UNION ALL
SELECT shipment_id, 'Customer Area', 'Delivered', NOW() - INTERVAL '1 day' FROM shipment WHERE order_id = 1
UNION ALL
SELECT shipment_id, 'Dhaka Hub', 'In Transit', NOW() - INTERVAL '2 day' FROM shipment WHERE order_id = 2;


