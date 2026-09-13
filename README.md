# TrackChain

An internal business management system for a company selling physical products — think an internal seller/ops dashboard, not a public storefront. Marketing, purchasing, warehouse, and shipment staff all work from one sidebar-navigated dashboard; a customer only ever sees two public pages (product catalog + shipment tracking). Built for a DBMS course project: PostgreSQL (via Supabase) handles all data logic — tables, triggers, functions, procedures, cursor, and analytics views — with a plain HTML/CSS/JS frontend.

## Tech stack

- **Database**: PostgreSQL, hosted on [Supabase](https://supabase.com) (free tier)
- **Frontend**: Plain HTML/CSS/JavaScript, no framework or build step
- **Connection**: [supabase-js](https://supabase.com/docs/reference/javascript) client, calling Supabase's auto-generated REST API

There is no custom backend server. All "backend logic" lives inside PostgreSQL itself, as triggers, functions, and procedures — this is intentional, and is explained in the project report.

## Who uses it

```
                    Admin
                      │
     ┌────────────────┼────────────────┐
     │                │                │
Purchasing        Marketing       Warehouse
 Officer           Manager         Manager
     │                │                │
     └────────────────┼────────────────┘
                      │
              Shipment Manager
                      │
                 Customer (public pages only)
```

Every internal page requires a real Supabase Auth login (`login/index.html`) — an admin creates each staff account and assigns its role from the in-app Staff Management page; there's no self-signup. Route guards restrict which sidebar pages each role can open, and the database enforces the same boundaries independently via row-level security (see [Setup step 4](#4-set-up-staff-authentication-admin--roles)). A customer never sees the sidebar or logs in at all — only `storefront/product.html` and `storefront/track.html`, both public.

## Project structure

```
trackchain/
├── database/
│   ├── schema.sql                                 -- tables, triggers, functions, procedures, cursor, views, staff auth, RLS (everything below, already included)
│   ├── seed_data.sql                              -- sample data for demo purposes
│   ├── migration_add_purchase_management.sql      -- adds Purchase Management to an existing DB
│   ├── migration_fix_purchase_integrity.sql       -- supplier-match check + delete-reversal fix
│   ├── migration_add_stock_transfers.sql          -- adds warehouse-to-warehouse Stock Transfers
│   ├── migration_add_warehouse_capacity_rent.sql  -- adds capacity, aging rent, and hub routing
│   ├── migration_add_staff_auth.sql               -- adds real Supabase Auth + staff_profiles (already in schema.sql for a fresh install)
│   ├── migration_add_business_table_rls.sql       -- enables RLS + role policies on the 17 business tables (already in schema.sql for a fresh install)
│   ├── migration_secure_analytics_views.sql       -- makes the analytics views respect the caller's RLS instead of the view owner's (already in schema.sql for a fresh install)
│   └── migration_fix_campaign_revenue.sql         -- fixes a revenue double-counting bug in campaign_performance/platform_performance (already in schema.sql for a fresh install)
└── frontend/
    ├── index.html               -- Dashboard Overview (KPIs, charts, top lists)
    ├── login/index.html         -- Staff login (Supabase Auth)
    ├── staff/index.html         -- Staff Management (admin-only: create/deactivate/reactivate/delete accounts)
    ├── suppliers/index.html     -- Supplier Management (add/edit/search)
    ├── products/index.html      -- Product Management (add/edit/search, margin-based pricing)
    ├── purchases/index.html     -- Purchase Management (record a purchase, see history)
    ├── warehouses/index.html    -- Warehouse (add/edit, capacity & derived rent, stock transfers, per-hub stock-age & flow view, hub routing preview)
    ├── inventory/index.html     -- Inventory (Current Stock / Low Stock tabs)
    ├── customers/index.html     -- Customer (list + manual add)
    ├── orders/index.html        -- Orders (New / History filter)
    ├── campaigns/index.html     -- Campaign Management (Campaigns / Tracking Links / Click Analytics tabs)
    ├── shipments/index.html     -- Shipment (Pending / In Transit / Delivered, advance status)
    ├── reports/index.html       -- Reports (the analytics views, with CSV export)
    ├── audit-logs/index.html    -- Audit Logs (filterable audit_log viewer)
    ├── storefront/
    │   ├── product.html         -- PUBLIC: product catalog + guest "Buy" (name+phone checkout)
    │   ├── redirect.html        -- PUBLIC: campaign tracking-link redirect + click logging
    │   └── track.html           -- PUBLIC: shipment tracking by TRK code
    ├── css/style.css            -- shared design system (sidebar shell + components)
    └── js/
        ├── sidebar.js           -- nav tree + renderSidebar() -- edit nav in one place
        ├── ui-helpers.js        -- shared badges/table/formatting helpers
        ├── config.example.js    -- template, safe to commit
        ├── config.js            -- your real keys, gitignored
        └── supabaseClient.js
```

Every internal page uses **root-relative** links (`/css/style.css`, `/orders/index.html`, …), so the site **must** be served from `frontend/` as the HTTP root — see Setup step 3. It will not work correctly opened directly via `file://`.

**Demo flow**: serve the site → Campaign Management → "Create campaign", pick which platforms to generate links for → click "Test this link" on one → it redirects through `storefront/redirect.html` (logs the click) → lands on `storefront/product.html` with that product highlighted and an attribution banner → click Buy, enter a name + phone (guest checkout: matched or created in `customer`) → order placed → back in Campaign Management, the click and the order/revenue show up within seconds (auto-refreshing). Check Orders, Shipments (advance its status), and `storefront/track.html` with the resulting `TRK` code to see the rest of the pipeline.

**Warehouse economics demo**: open Warehouse Management — each hub shows live capacity utilisation and a rent rate that's *derived* from its size, not typed in (a bigger hub is cheaper per unit, automatically). Open a hub's detail view for its stock-age breakdown (Fresh / Aging / Stale / Dead stock — dead stock is billed at 3x rent) and its per-hub Stock In / Stock Out flow, both reconstructed live from purchase and order history, no extra bookkeeping table involved. Try a Stock Transfer between two hubs — the moved units keep their original arrival date, so a hub can't dodge its aging surcharge just by shuffling stock elsewhere. Then open the hub routing preview for a product to see which warehouse the system would ship an order from, and why (it prefers relieving whichever hub is carrying the most aging surcharge on that product).

## Setup — one-time

### 1. Create the Supabase project
1. Go to [supabase.com](https://supabase.com) → New project
2. Wait for it to finish provisioning (~2 minutes)
3. Go to **Project Settings → API** and copy your **Project URL** and **anon public key**

### 2. Create the database
1. In your Supabase project, open the **SQL Editor**
2. Paste the entire contents of `database/schema.sql` → click **Run**
3. Paste the entire contents of `database/seed_data.sql` → click **Run**
4. Sanity check: run `SELECT * FROM campaign_performance;` — you should see rows with real numbers

### 3. Connect and serve the frontend
1. Copy `frontend/js/config.example.js` to `frontend/js/config.js`
2. Open `config.js` and paste in your Project URL and anon key from step 1
3. Serve the `frontend/` folder as a local web server (**required**, not optional — the dashboard uses root-relative paths):
   ```
   cd frontend
   python3 -m http.server 8080
   ```
4. Open `http://localhost:8080/` — the Dashboard Overview should load real data

`config.js` is listed in `.gitignore` so your key never gets pushed to GitHub. Anyone cloning this repo must create their own `config.js` from the example file.

### 4. Set up staff authentication (admin + roles)

Login is real Supabase Auth now — no hardcoded passwords, no self-signup. An admin creates every other account from inside the app. `schema.sql` (step 2) already created `staff_profiles`, `current_staff_role()`, and RLS policies on every business table — there's no separate migration to run for a fresh install. One-time setup from here:

1. **Create the first admin manually** (bootstrap — every account after this one is created in-app instead):
   - Dashboard → **Authentication → Users → Add User** — real email, a password, toggle **Auto Confirm User** on.
   - Copy that user's UUID, then in the SQL Editor:
     ```sql
     INSERT INTO public.staff_profiles (id, email, full_name, role, is_active)
     VALUES ('<paste-the-uuid>', '<same-email>', '<your-name>', 'admin', TRUE);
     ```
2. **Deploy the admin edge function** (this is what lets the admin create/deactivate/delete staff from the UI — it's the only place the service role key is ever used, and it never reaches the browser):
   ```
   npm install -g supabase
   supabase login
   supabase link --project-ref xcufebaylsbpziwsljye
   supabase functions deploy admin-manage-staff
   ```
3. Sign in at `/login/index.html` with the admin account from step 1 → **Staff Management** in the sidebar → create the Purchasing/Marketing/Warehouse/Shipment accounts for your team from there.

If instead you're upgrading an **already-deployed** project created from an older copy of `schema.sql` (one that ended in `DISABLE ROW LEVEL SECURITY`), run these once, in this exact order, in the SQL Editor before the steps above: `migration_add_staff_auth.sql` → `migration_add_business_table_rls.sql` → `migration_fix_campaign_revenue.sql` → `migration_secure_analytics_views.sql`. The last one must run last: `CREATE OR REPLACE VIEW` (used by the revenue fix) resets a view's `security_invoker` setting back off, so if you ever re-run the revenue fix after the security fix, just run `migration_secure_analytics_views.sql` once more afterward.

Deactivating a staff account blocks their next login immediately (checked on every page load) without deleting their order/purchase/audit history. There's always at least one active admin required — the function refuses to deactivate or delete the last one.

## What each database object does (for the report / viva)

| Object | Type | Purpose |
|---|---|---|
| `trg_reduce_inventory` | Trigger | Reduces stock automatically when an order_item is inserted; blocks the order if stock is insufficient |
| `trg_increase_inventory` | Trigger | Mirror image, on `purchase_item`: increases (upserts) stock when a purchase is recorded |
| `trg_generate_tracking_code` | Trigger | Auto-generates `TRK<id>` shipment tracking codes |
| `trg_create_shipment_on_order` | Trigger | Auto-creates a shipment (status `Packed`) the moment an order is placed |
| `trg_generate_short_code` | Trigger | Auto-generates a realistic tracking short code (e.g. `FB-A7K92`) when one isn't supplied manually |
| `trg_audit_order`, `trg_audit_inventory`, `trg_audit_purchase` | Triggers | Log every insert/update/delete to `audit_log` |
| `campaign_revenue(id)` | Function | Total revenue generated by a campaign (via `order_attribution`) — SQL Editor/viva only, not called from any page |
| `low_stock_products(threshold)` | Function | Products below a stock threshold |
| `place_order(...)` / `place_order_api(...)` | Procedure / Function | Places an order + attribution in one transaction — procedure for SQL Editor/viva, function for the frontend RPC |
| `place_purchase(...)` / `place_purchase_api(...)` | Procedure / Function | Same pattern, inbound side: records a purchase and fires `trg_increase_inventory` |
| `pending_shipment_report()` | Function (cursor) | Loops through undelivered shipments and reports days pending |
| `campaign_performance`, `platform_performance`, `supplier_product_count`, `purchase_history` | Views | Power the Reports/Dashboard/Purchases pages |
| `rent_per_unit_day` | Generated column | On `warehouse`, derived from `capacity_units` (bigger hub = cheaper per unit) — cannot be hand-set, recomputes automatically |
| `trg_enforce_warehouse_capacity` | Trigger | Blocks a purchase/transfer that would push a warehouse over its `capacity_units` |
| `trg_check_capacity_not_below_stock` | Trigger | Blocks lowering a warehouse's capacity below what's currently stored in it |
| `storage_age_multiplier(days)` / `storage_age_band(days)` | Functions | Rent multiplier (1x/1.5x/2x/3x) and label (Fresh/Aging/Stale/Dead stock) for how long a unit has sat in a warehouse |
| `warehouse_stock_age` | View | Reconstructs each unit's arrival date (FIFO, from purchase + transfer history) and its age-based rent |
| `warehouse_capacity`, `warehouse_rent`, `warehouse_overview` | Views | Live utilisation/status, aging-adjusted daily & monthly rent, and the combined view the Warehouse page reads |
| `transfer_stock_api(...)` | Function | Moves stock between warehouses; carries each unit's original arrival date so aging rent survives the move |
| `pick_source_warehouse(product, qty)` / `hub_routing_preview(product, qty)` | Functions | Recommend which warehouse should fulfil an order line (prefers relieving the hub with the most aging surcharge on that product); the preview version returns every candidate hub and why it won or lost |
| `order_fulfilment` | View | Ties each order back to the hub it actually shipped from — powers the per-warehouse Stock In/Out flow |
| `staff_profiles` / `current_staff_role()` | Table / Function | Backs real Supabase Auth login: one row per staff account (role, active flag); `current_staff_role()` is a `SECURITY DEFINER` helper every RLS policy calls to check the caller's role |
| Row-level security policies (Section 11) | Policies | Every business table restricts SELECT to logged-in staff and scopes INSERT/UPDATE/DELETE to the specific role that owns that write in the UI (e.g. only `marketing`/`admin` can write `campaign`); the public storefront gets its own narrow anon-only policies |

## Why `order_attribution` is a separate table

`order` only stores facts about the purchase itself (customer, date). Whether a campaign caused it is a separate concern, tracked in `order_attribution` (order_id + link_id). This keeps the core order model clean and makes it possible to extend attribution logic later without touching the order table.

## Why `purchase` / `purchase_item` exist

Inventory should never "magically" increase — every unit of stock is traceable to a purchase from a specific supplier into a specific warehouse, at a specific cost. This mirrors `order`/`order_item` exactly, just for the inbound side, and answers questions like "who supplied this inventory" and "which supplier do we buy the most from" (see `purchase_history`).

## Why warehouse rent is a generated column, not a typed-in field

Rent and capacity aren't independent: bulk storage costs less per unit, so a bigger hub charges a lower rate. That makes `capacity_units → rent_per_unit_day` a functional dependency, and storing a rate someone typed by hand would let the two disagree — the classic update anomaly, where enlarging a warehouse silently leaves it on its old small-hub rate. `rent_per_unit_day` is declared `GENERATED ALWAYS ... STORED`, so Postgres recomputes it itself whenever `capacity_units` changes, and it can't be hand-edited at all.

Stock age works the same way: `inventory` only holds a running quantity per (warehouse, product), with no arrival date. `warehouse_stock_age` rebuilds age from `purchase`/`stock_transfer` history instead (FIFO: the newest-purchased units are assumed to be the ones still on hand), so a unit older than 30/60/90 days accrues a 1.5x/2x/3x rent surcharge without a single extra column on `inventory`.

Hub routing (`pick_source_warehouse`) exists to reduce that surcharge: when an order can be filled by more than one warehouse, it ships from whichever hub is carrying the most aging surcharge on that product, not just whichever hub is closest to empty. Splitting one order line across two hubs is deliberately out of scope — it would need a per-item fulfilment record, i.e. a new table — so `pick_source_warehouse` returns `NULL` when no single hub can cover the full quantity, and that order shows up in `order_fulfilment` as unattributed to any one hub.

## Known simplifications (documented on purpose)

- **Public storefront RLS policies are broader than a real production system would allow** — the anon key can read every row of `product`, `inventory`, `customer`, `shipment`, `shipment_status`, `campaign`, and `tracking_link` (see Section 11.4 of `schema.sql`), not just the rows a given visitor actually needs. Acceptable for a closed academic demo with no real customer data, not for a real deployment.
- **Guest checkout (`place_order_api`) is a public function with no ownership check** — anyone with the anon key can submit an order under an arbitrary `customer_id` or attribute it to an arbitrary `tracking_link_id` via a direct API call, not just through the storefront UI. Fine for a controlled demo, not safe for a real public shop.
- **Campaign `start_date`/`end_date` are stored but not enforced** — nothing in the database blocks an expired or not-yet-started campaign's tracking links from logging clicks or attributing orders; enforcement exists only as a possible UI-level improvement, not yet implemented.
- **Shipment status order is enforced only by the UI** — the database allows a direct insert of any status (`Packed`/`In Transit`/`Out For Delivery`/`Delivered`) in any order or a duplicate status; there is no trigger validating the sequence.
- **Click-to-order attribution** is per-link (via the `code` query param carried from redirect → storefront → order), not full session tracking.
- **Country detection** on the redirect page uses a free third-party IP geolocation API (`ipapi.co`) — this is genuinely how real ad platforms do it, but is best-effort; the fetch has a hard 2.5s timeout so a slow/unavailable geolocation service can never block click logging itself.
- **Guest checkout** identifies a customer by phone number (match existing, or create new) — there's no login, so this is the simplest correct way to avoid one real person becoming multiple `customer` rows.
- **Hub routing picks a single warehouse per order**, never splits one order line across two hubs. An order no single hub can fully cover is left unattributed (`source_warehouse_id` is `NULL` in `order_fulfilment`) rather than partially fulfilled.

## Team

Procheta Silvie (230042114)
Tasnia Farzana  (230042124)
Aksan Anan Ria  (230042154)
