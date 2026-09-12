// TrackChain Role-Based Access Control (RBAC) & Authentication Engine
// Backed by real Supabase Auth accounts + the staff_profiles table.
// Accounts are provisioned by an admin (see /staff/index.html), never
// self-signed-up and never hardcoded here.

const ROLES = {
    admin: {
        id: "admin",
        label: "Admin",
        icon: "👑",
        description: "Full access across all modules, metrics, reports, audit logs & staff accounts",
        allowedKeys: [
            "dashboard", "suppliers", "products", "warehouses", "purchases",
            "inventory", "customers", "orders", "campaigns", "shipments",
            "reports", "audit-logs", "staff"
        ]
    },
    purchasing: {
        id: "purchasing",
        label: "Purchasing Officer",
        icon: "🧾",
        description: "Sourcing, supplier management, product creation & purchase records",
        allowedKeys: ["dashboard", "suppliers", "products", "purchases", "inventory", "reports"]
    },
    marketing: {
        id: "marketing",
        label: "Marketing Manager",
        icon: "📣",
        description: "Campaign tracking, conversion analytics, customer list & storefront impact",
        allowedKeys: ["dashboard", "campaigns", "customers", "reports"]
    },
    warehouse: {
        id: "warehouse",
        label: "Warehouse Manager",
        icon: "🏬",
        description: "Hub capacity, stock transfers, product catalog & inventory levels",
        allowedKeys: ["dashboard", "products", "warehouses", "inventory", "reports"]
    },
    shipment: {
        id: "shipment",
        label: "Shipment Manager",
        icon: "🚚",
        description: "Order processing, tracking numbers, stock checks & status updates",
        allowedKeys: ["dashboard", "inventory", "orders", "shipments", "reports"]
    }
};

const PAGE_LABELS = {
    dashboard: "Dashboard Overview", suppliers: "Supplier Management", products: "Product Management",
    warehouses: "Warehouse", purchases: "Purchase Management", inventory: "Inventory",
    customers: "Customer", orders: "Orders", campaigns: "Campaign Management", shipments: "Shipment",
    reports: "Reports", "audit-logs": "Audit Logs", staff: "Staff Management"
};
const PAGE_HREFS = {
    dashboard: "/index.html", suppliers: "/suppliers/index.html", products: "/products/index.html",
    warehouses: "/warehouses/index.html", purchases: "/purchases/index.html", inventory: "/inventory/index.html",
    customers: "/customers/index.html", orders: "/orders/index.html", campaigns: "/campaigns/index.html",
    shipments: "/shipments/index.html", reports: "/reports/index.html", "audit-logs": "/audit-logs/index.html",
    staff: "/staff/index.html"
};

// Populated by initAuth(); every page must await it before calling
// checkPageAccess/renderSidebar/renderUserHeaderProfile.
let _cachedUser = null;

async function initAuth() {
    const { data: { session } } = await supabaseClient.auth.getSession();
    if (!session) {
        _cachedUser = null;
        return null;
    }

    const { data: profile } = await supabaseClient
        .from("staff_profiles")
        .select("full_name, role, is_active")
        .eq("id", session.user.id)
        .single();

    if (!profile || !profile.is_active) {
        // Deleted, deactivated, or never provisioned -- don't leave a dangling session.
        await supabaseClient.auth.signOut();
        _cachedUser = null;
        return null;
    }

    const roleObj = ROLES[profile.role];
    _cachedUser = {
        id: session.user.id,
        email: session.user.email,
        username: profile.full_name,
        roleId: profile.role,
        roleName: roleObj ? roleObj.label : profile.role
    };
    return _cachedUser;
}

function getLoggedInUser() {
    return _cachedUser;
}

async function loginWithPassword(email, password) {
    const { error } = await supabaseClient.auth.signInWithPassword({
        email: (email || "").trim().toLowerCase(),
        password: password || ""
    });
    if (error) {
        return { success: false, message: "Invalid email or password. Please try again." };
    }

    await initAuth();
    if (!_cachedUser) {
        return { success: false, message: "This account has no active staff role. Contact your admin." };
    }
    return { success: true };
}

async function logout() {
    await supabaseClient.auth.signOut();
    _cachedUser = null;
    window.location.href = "/login/index.html";
}

// Bearer token for calling the admin-manage-staff edge function.
async function getAccessToken() {
    const { data: { session } } = await supabaseClient.auth.getSession();
    return session ? session.access_token : null;
}

function canRoleAccess(roleId, pageKey) {
    if (!roleId || !ROLES[roleId]) return false;
    return ROLES[roleId].allowedKeys.includes(pageKey);
}

// Every module page calls this (after awaiting initAuth()) before rendering.
async function checkPageAccess(pageKey) {
    if (window.location.pathname.includes("/storefront/") || window.location.pathname.includes("/login/")) {
        return true;
    }

    const user = getLoggedInUser();
    if (!user) {
        window.location.href = "/login/index.html";
        return false;
    }

    if (!canRoleAccess(user.roleId, pageKey)) {
        renderAccessRestrictedPage(pageKey, user.roleId);
        return false;
    }

    return true;
}

function renderUserHeaderProfile(mountId = "role-selector-mount") {
    const mount = document.getElementById(mountId);
    if (!mount) return;

    const user = getLoggedInUser();
    if (!user) {
        mount.innerHTML = `<a href="/login/index.html" class="btn primary btn-small">Sign In</a>`;
        return;
    }

    const roleObj = ROLES[user.roleId];
    mount.innerHTML = `
        <div class="user-header-profile">
            <div class="user-info-text">
                <span class="user-name">${user.username}</span>
                <span class="user-role-badge">${roleObj ? roleObj.icon : ""} ${roleObj ? roleObj.label : user.roleId}</span>
            </div>
            <button type="button" class="btn-logout" onclick="logout()" title="Log out of session">
                <span>🚪</span> Log Out
            </button>
        </div>
    `;
}

function renderAccessRestrictedPage(pageKey, activeRole) {
    const main = document.querySelector(".shell-main") || document.body;
    const roleObj = ROLES[activeRole] || ROLES.admin;
    const user = getLoggedInUser();

    const allowedModulesHtml = roleObj.allowedKeys.map(key => {
        return `<a href="${PAGE_HREFS[key]}" class="btn secondary">${PAGE_LABELS[key]}</a>`;
    }).join(" ");

    main.innerHTML = `
        <header class="shell-header">
            <div>
                <h1>Access Restricted</h1>
                <p>Role-Based Security Policy</p>
            </div>
            <div id="role-selector-mount"></div>
        </header>
        <main class="shell-content">
            <div class="card access-restricted-card">
                <div class="access-restricted-icon">🔒</div>
                <h2>Module Access Restricted</h2>
                <p>Hello <strong>${user ? user.username : "User"}</strong>, your current role <strong>${roleObj.icon} ${roleObj.label}</strong> does not have permission to view or edit this module.</p>
                <p class="role-desc-sub">${roleObj.description}</p>
                <div class="access-restricted-actions">
                    <p><strong>Available modules for your role:</strong></p>
                    <div style="display: flex; gap: 8px; flex-wrap: wrap; margin-top: 12px; justify-content: center;">
                        ${allowedModulesHtml}
                    </div>
                </div>
            </div>
        </main>
    `;

    renderUserHeaderProfile();
}
