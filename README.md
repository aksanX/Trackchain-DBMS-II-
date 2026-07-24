# Trackchain-DBMS-II
# System Modules  
1. Supply Chain Management — manage suppliers and product details, store products in warehouses, track inventory quantity, identify low-stock products.  
2. Customer Order Management — store customer information, record customer orders, support multiple products in one order, reduce inventory after order placement.  
3. Campaign Analytics — create product-based campaigns, generate platform tracking links, track customer clicks, analyze campaign performance and sales impact.  
4. Shipment Tracking — create shipment for each order, generate unique tracking code, update shipment status, track delivery progress until delivered.  
# Overall System Workflow  
Supplier — Suppliers provide products to the system  
Product — Products are added to the product catalog  
Inventory — Products are stored in warehouses and stock is updated  
Campaign — Marketing campaigns are created for promotion  
Tracking Link — Unique tracking links are generated for each platform  
Customer Click — Customers click on the tracking links from platforms  
Order — Customers place orders through the system  
Inventory Update — Inventory is deducted based on the ordered items  
Shipment — Shipment is created and products are dispatched  
Shipment Status — Shipment status is updated until delivery  
Delivery — Products are delivered to the customer

File Structure:   
trackchain/ <br>
├── sql/ <br> 
│   ├── schema/          # CREATE TABLE statements <br>
│   ├── functions/       # PL/pgSQL functions  <br>
│   ├── procedures/      # PL/pgSQL stored procedures <br>
│   ├── triggers/        # Trigger definitions <br>
│   └── seed/            # Sample/seed data  <br>
├── frontend/ <br>
│   ├── index.html <br>
│   ├── css/ <br>
│   └── js/ <br>
├── docs/ <br>
│   ├── ERD.png <br>
│   └── TrackChain.pdf   # Project proposal slides <br>
├── .devcontainer/        # Codespace configuration <br>
└── README.md <br>
