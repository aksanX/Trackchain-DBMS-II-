// Small helpers shared by every internal dashboard page: escaping,
// formatting, table rendering, and the platform/status badge vocabulary
// used consistently across Campaigns, Orders, Shipments, etc.

function escapeHtml(str) {
    if (str === null || str === undefined) return "";
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function formatMoney(n) {
    const v = Number(n) || 0;
    return "৳" + v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function formatDate(d) {
    if (!d) return "-";
    return new Date(d).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

function formatDateTime(d) {
    if (!d) return "-";
    return new Date(d).toLocaleString();
}

async function fillTable(tableId, rows, rowMapper, colspan) {
    const tbody = document.querySelector(`#${tableId} tbody`);
    if (!tbody) return;
    tbody.innerHTML = "";
    if (!rows || rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="${colspan}">No data yet</td></tr>`;
        return;
    }
    rows.forEach(row => {
        const tr = document.createElement("tr");
        tr.innerHTML = rowMapper(row);
        tbody.appendChild(tr);
    });
}

const PLATFORMS = ["Facebook", "Instagram", "WhatsApp", "Email"];

const PLATFORM_COLOR = {
    Facebook:  "#2a78d6",
    Instagram: "#eb6834",
    WhatsApp:  "#1baf7a",
    Email:     "#eda100"
};

const PLATFORM_CLASS = {
    Facebook:  "badge-platform-facebook",
    Instagram: "badge-platform-instagram",
    WhatsApp:  "badge-platform-whatsapp",
    Email:     "badge-platform-email"
};

function platformBadge(platform) {
    if (!platform) return "-";
    const cls = PLATFORM_CLASS[platform] || "";
    return `<span class="badge ${cls}"><span class="badge-dot"></span>${escapeHtml(platform)}</span>`;
}

const SHIPMENT_STATUS_ORDER = ["Packed", "In Transit", "Out For Delivery", "Delivered"];

const SHIPMENT_STATUS_COLOR = {
    "Packed": "#86b6ef",
    "In Transit": "#5598e7",
    "Out For Delivery": "#2a78d6",
    "Delivered": "#184f95"
};

function statusClass(status) {
    return "badge-status-" + (status || "").toLowerCase().replace(/\s+/g, "-");
}

function statusBadge(status) {
    if (!status) return `<span class="badge badge-neutral">No shipment</span>`;
    return `<span class="badge ${statusClass(status)}">${escapeHtml(status)}</span>`;
}

function nextShipmentStatus(current) {
    const idx = SHIPMENT_STATUS_ORDER.indexOf(current);
    if (idx === -1 || idx === SHIPMENT_STATUS_ORDER.length - 1) return null;
    return SHIPMENT_STATUS_ORDER[idx + 1];
}

// Wires up a .page-tabs button group: each button needs data-tab="<panel-id>",
// each panel needs a matching id and class="tab-panel". First button with
// class="active" (or the first button) determines the initial panel.
function initPageTabs(tabsSelector) {
    const buttons = Array.from(document.querySelectorAll(`${tabsSelector} button[data-tab]`));
    buttons.forEach(btn => {
        btn.addEventListener("click", () => {
            buttons.forEach(b => b.classList.remove("active"));
            btn.classList.add("active");
            document.querySelectorAll(".tab-panel").forEach(p => p.classList.remove("active"));
            const panel = document.getElementById(btn.dataset.tab);
            if (panel) panel.classList.add("active");
        });
    });
}
