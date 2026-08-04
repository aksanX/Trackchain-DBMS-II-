# SupplySphere

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

No login system exists (same trust model the project has always had — this is a closed academic demo). Every internal module is visible to whoever loads the dashboard; a customer never sees the sidebar at all, only `storefront/product.html` and `storefront/track.html`.

## Project structure

```
supplysphere/
├── database/
│   ├── schema.sql              -- tables, triggers, functions, procedures, cursor, views
│   └── seed_data.sql           -- sample data for demo purposes
└── frontend/
    ├── index.html               -- Dashboard Overview (KPIs, charts, top lists)
    ├── suppliers/index.html     -- Supplier Management (add/edit/search)
    ├── products/index.html      -- Product Management (add/edit/search)
    ├── purchases/index.html     -- Purchase Management (record a purchase, see history)
    ├── warehouses/index.html    -- Warehouse (add/edit)
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

## What each database object does (for the report / viva)

| Object | Type | Purpose |
|---|---|---|
| `trg_reduce_inventory` | Trigger | Reduces stock automatically when an order_item is inserted; blocks the order if stock is insufficient |
| `trg_increase_inventory` | Trigger | Mirror image, on `purchase_item`: increases (upserts) stock when a purchase is recorded |
| `trg_generate_tracking_code` | Trigger | Auto-generates `TRK<id>` shipment tracking codes |
| `trg_create_shipment_on_order` | Trigger | Auto-creates a shipment (status `Packed`) the moment an order is placed |
| `trg_generate_short_code` | Trigger | Auto-generates a realistic tracking short code (e.g. `FB-A7K92`) when one isn't supplied manually |
| `trg_audit_order`, `trg_audit_inventory`, `trg_audit_purchase` | Triggers | Log every insert/update/delete to `audit_log` |
| `campaign_revenue(id)` | Function | Total revenue generated by a campaign (via `order_attribution`) |
| `low_stock_products(threshold)` | Function | Products below a stock threshold |
| `place_order(...)` / `place_order_api(...)` | Procedure / Function | Places an order + attribution in one transaction — procedure for SQL Editor/viva, function for the frontend RPC |
| `place_purchase(...)` / `place_purchase_api(...)` | Procedure / Function | Same pattern, inbound side: records a purchase and fires `trg_increase_inventory` |
| `pending_shipment_report()` | Function (cursor) | Loops through undelivered shipments and reports days pending |
| `campaign_performance`, `platform_performance`, `supplier_product_count`, `purchase_history` | Views | Power the Reports/Dashboard/Purchases pages |

## Why `order_attribution` is a separate table

`order` only stores facts about the purchase itself (customer, date). Whether a campaign caused it is a separate concern, tracked in `order_attribution` (order_id + link_id). This keeps the core order model clean and makes it possible to extend attribution logic later without touching the order table.

## Why `purchase` / `purchase_item` exist

Inventory should never "magically" increase — every unit of stock is traceable to a purchase from a specific supplier into a specific warehouse, at a specific cost. This mirrors `order`/`order_item` exactly, just for the inbound side, and answers questions like "who supplied this inventory" and "which supplier do we buy the most from" (see `purchase_history`).

## Known simplifications (documented on purpose)

- **No authentication** — every internal module is visible to anyone who loads the dashboard. The 6 roles in the brief describe *who conceptually uses which module*, not an access-control system; adding real auth is a separate, larger undertaking out of scope here.
- **Row Level Security is disabled** on all tables for this demo — acceptable for a closed academic project with no real user data, not for production.
- **Click-to-order attribution** is per-link (via the `code` query param carried from redirect → storefront → order), not full session tracking.
- **Country detection** on the redirect page uses a free third-party IP geolocation API (`ipapi.co`) — this is genuinely how real ad platforms do it, but is best-effort; the fetch has a hard 2.5s timeout so a slow/unavailable geolocation service can never block click logging itself.
- **Guest checkout** identifies a customer by phone number (match existing, or create new) — there's no login, so this is the simplest correct way to avoid one real person becoming multiple `customer` rows.

## Team

Procheta Silvie (230042154)
Tasnia Farzana  (230042124)
Aksan Anan Ria  (230042154)
