// Shared internal-dashboard sidebar. Every module page includes
// <div id="sidebar-mount"></div>, loads this file, and calls
// renderSidebar('<own-key>') -- edit the nav in exactly one place.
//
// FIX: grouped into sections (Setup / Operations / Insights) so the
// sidebar itself teaches the correct workflow order. Previously
// "Purchase Management" was listed before "Warehouse" even though a
// purchase requires an existing warehouse -- a user following the
// sidebar top-to-bottom would hit a dead end. Setup items (which
// everything else depends on) are now grouped and ordered first:
// Suppliers -> Products -> Warehouse.

// Outline icon set (Feather-style). Each entry is the inner markup of a
// 24x24 stroke-based <svg>, rendered with currentColor so it inherits the
// link's text color (including hover/active states) instead of emoji glyphs.
const SIDEBAR_ICONS = {
    dashboard: '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>',
    suppliers: '<path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1" ry="1"/><line x1="8" y1="12" x2="16" y2="12"/><line x1="8" y1="16" x2="16" y2="16"/>',
    products: '<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>',
    warehouses: '<polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5"/><line x1="10" y1="12" x2="14" y2="12"/>',
    purchases: '<path d="M6 2L3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4z"/><line x1="3" y1="6" x2="21" y2="6"/><path d="M16 10a4 4 0 0 1-8 0"/>',
    inventory: '<line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>',
    customers: '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    orders: '<circle cx="9" cy="21" r="1"/><circle cx="20" cy="21" r="1"/><path d="M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6"/>',
    campaigns: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
    shipments: '<rect x="1" y="3" width="15" height="13"/><polygon points="16 8 20 8 23 11 23 16 16 16 16 8"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/>',
    reports: '<polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/>',
    "audit-logs": '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>',
    "external-link": '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/>'
};

function sidebarIcon(key) {
    return `<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${SIDEBAR_ICONS[key] || ""}</svg>`;
}

const SIDEBAR_SECTIONS = [
    {
        label: null, // no header for the single "home" link
        items: [
            { key: "dashboard", label: "Dashboard Overview", href: "/index.html", icon: "dashboard" }
        ]
    },
    {
        label: "Setup",
        items: [
            { key: "suppliers",  label: "Supplier Management", href: "/suppliers/index.html",  icon: "suppliers" },
            { key: "products",   label: "Product Management",  href: "/products/index.html",   icon: "products" },
            { key: "warehouses", label: "Warehouse",            href: "/warehouses/index.html", icon: "warehouses" }
        ]
    },
    {
        label: "Operations",
        items: [
            { key: "purchases",  label: "Purchase Management", href: "/purchases/index.html", icon: "purchases" },
            { key: "inventory",  label: "Inventory",            href: "/inventory/index.html", icon: "inventory" },
            { key: "customers",  label: "Customer",             href: "/customers/index.html", icon: "customers" },
            { key: "orders",     label: "Orders",               href: "/orders/index.html",    icon: "orders" },
            { key: "campaigns",  label: "Campaign Management",  href: "/campaigns/index.html", icon: "campaigns" },
            { key: "shipments",  label: "Shipment",             href: "/shipments/index.html", icon: "shipments" }
        ]
    },
    {
        label: "Insights",
        items: [
            { key: "reports",    label: "Reports",    href: "/reports/index.html",    icon: "reports" },
            { key: "audit-logs", label: "Audit Logs", href: "/audit-logs/index.html", icon: "audit-logs" }
        ]
    }
];

const SIDEBAR_PUBLIC_LINKS = [
    { label: "Product Page",   href: "/storefront/product.html" },
    { label: "Track Shipment", href: "/storefront/track.html" }
];

function renderSidebar(activeKey) {
    const mount = document.getElementById("sidebar-mount");
    if (!mount) return;

    const sectionsHtml = SIDEBAR_SECTIONS.map(section => {
        const linksHtml = section.items.map(item => `
            <a class="sidebar-link${item.key === activeKey ? " active" : ""}" href="${item.href}">
                ${sidebarIcon(item.icon)}${item.label}
            </a>
        `).join("");
        const labelHtml = section.label ? `<div class="sidebar-section-label">${section.label}</div>` : "";
        return `<nav class="sidebar-section">${labelHtml}${linksHtml}</nav>`;
    }).join("");

    const publicHtml = SIDEBAR_PUBLIC_LINKS.map(item => `
        <a class="sidebar-link public-link" href="${item.href}" target="_blank" rel="noopener">
            ${sidebarIcon("external-link")}${item.label}
        </a>
    `).join("");

    mount.innerHTML = `
        <a class="sidebar-brand" href="/index.html">
            <div class="logo-mark">S</div>
            <div>
                <span class="brand-name">TrackChain</span>
                <span class="brand-tag">Internal Dashboard</span>
            </div>
        </a>
        ${sectionsHtml}
        <div class="sidebar-section">
            <div class="sidebar-section-label">Public pages</div>
            ${publicHtml}
        </div>
    `;
}