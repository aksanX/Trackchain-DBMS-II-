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

const SIDEBAR_SECTIONS = [
    {
        label: null, // no header for the single "home" link
        items: [
            { key: "dashboard", label: "Dashboard Overview", href: "/index.html", icon: "🏠" }
        ]
    },
    {
        label: "Setup",
        items: [
            { key: "suppliers",  label: "Supplier Management", href: "/suppliers/index.html",  icon: "🏭" },
            { key: "products",   label: "Product Management",  href: "/products/index.html",   icon: "📦" },
            { key: "warehouses", label: "Warehouse",            href: "/warehouses/index.html", icon: "🏬" }
        ]
    },
    {
        label: "Operations",
        items: [
            { key: "purchases",  label: "Purchase Management", href: "/purchases/index.html", icon: "🧾" },
            { key: "inventory",  label: "Inventory",            href: "/inventory/index.html", icon: "📊" },
            { key: "customers",  label: "Customer",             href: "/customers/index.html", icon: "👥" },
            { key: "orders",     label: "Orders",               href: "/orders/index.html",    icon: "🛒" },
            { key: "campaigns",  label: "Campaign Management",  href: "/campaigns/index.html", icon: "📣" },
            { key: "shipments",  label: "Shipment",             href: "/shipments/index.html", icon: "🚚" }
        ]
    },
    {
        label: "Insights",
        items: [
            { key: "reports",    label: "Reports",    href: "/reports/index.html",    icon: "📈" },
            { key: "audit-logs", label: "Audit Logs", href: "/audit-logs/index.html", icon: "📜" }
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
                <span class="icon">${item.icon}</span>${item.label}
            </a>
        `).join("");
        const labelHtml = section.label ? `<div class="sidebar-section-label">${section.label}</div>` : "";
        return `<nav class="sidebar-section">${labelHtml}${linksHtml}</nav>`;
    }).join("");

    const publicHtml = SIDEBAR_PUBLIC_LINKS.map(item => `
        <a class="sidebar-link public-link" href="${item.href}" target="_blank" rel="noopener">
            <span class="icon">↗</span>${item.label}
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