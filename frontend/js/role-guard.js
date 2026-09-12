// TrackChain Role-Based Access Control (RBAC) & Authentication Engine
// Supports Username & Password authentication, session locking, route guards, and logout.

const ROLES = {
    admin: {
        id: "admin",
        label: "Admin",
        icon: "👑",
        description: "Full access across all modules, metrics, reports & audit logs",
        allowedKeys: [
            "dashboard", "suppliers", "products", "warehouses", "purchases",
            "inventory", "customers", "orders", "campaigns", "shipments",
            "reports", "audit-logs"
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

// Staff user accounts with username and password
const STAFF_ACCOUNTS = {
    "admin":      { username: "admin",      password: "123", name: "Alex Admin",       roleId: "admin" },
    "purchasing": { username: "purchasing", password: "123", name: "Sarah Purchasing",  roleId: "purchasing" },
    "marketing":  { username: "marketing",  password: "123", name: "Marcus Marketing", roleId: "marketing" },
    "warehouse":  { username: "warehouse",  password: "123", name: "David Warehouse",  roleId: "warehouse" },
    "shipment":   { username: "shipment",   password: "123", name: "Elena Shipment",   roleId: "shipment" }
};

const SESSION_STORAGE_KEY = "trackchain_session_user";

function getLoggedInUser() {
    const raw = localStorage.getItem(SESSION_STORAGE_KEY) || sessionStorage.getItem(SESSION_STORAGE_KEY);
    if (!raw) return null;
    try {
        const user = JSON.parse(raw);
        if (user && ROLES[user.roleId]) {
            return user;
        }
    } catch (e) {
        console.error("Invalid session format", e);
    }
    return null;
}

function authenticateUser(username, password, remember = true) {
    const cleanUser = (username || "").trim().toLowerCase();
    const cleanPass = (password || "").trim();

    const account = Object.values(STAFF_ACCOUNTS).find(
        acc => acc.username.toLowerCase() === cleanUser && acc.password === cleanPass
    );

    if (!account) {
        return { success: false, message: "Invalid username or password. Please try again." };
    }

    const roleObj = ROLES[account.roleId];

    const userSession = {
        username: account.name,
        userLoginHandle: account.username,
        roleId: account.roleId,
        roleName: roleObj ? roleObj.label : account.roleId,
        loginTime: new Date().toISOString()
    };

    const storage = remember ? localStorage : sessionStorage;
    localStorage.removeItem(SESSION_STORAGE_KEY);
    sessionStorage.removeItem(SESSION_STORAGE_KEY);
    storage.setItem(SESSION_STORAGE_KEY, JSON.stringify(userSession));

    return { success: true };
}

function loginAsQuick(roleId) {
    const acc = STAFF_ACCOUNTS[roleId];
    if (acc) {
        return authenticateUser(acc.username, acc.password);
    }
    return { success: false, message: "Role account not found." };
}

function logout() {
    localStorage.removeItem(SESSION_STORAGE_KEY);
    sessionStorage.removeItem(SESSION_STORAGE_KEY);
    window.location.href = "/login/index.html";
}

function canRoleAccess(roleId, pageKey) {
    if (!roleId || !ROLES[roleId]) return false;
    return ROLES[roleId].allowedKeys.includes(pageKey);
}

function checkPageAccess(pageKey) {
    // Exclude public pages and login page from guard check
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
        mount.innerHTML = `
            <a href="/login/index.html" class="btn primary btn-small">Sign In</a>
        `;
        return;
    }

    const roleObj = ROLES[user.roleId];

    mount.innerHTML = `
        <div class="user-header-profile">
            <div class="user-info-text">
                <span class="user-name">${user.username}</span>
                <span class="user-role-badge">${roleObj ? roleObj.icon : ''} ${roleObj ? roleObj.label : user.roleId}</span>
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
        const labels = {
            dashboard: "Dashboard Overview",
            suppliers: "Supplier Management",
            products: "Product Management",
            warehouses: "Warehouse",
            purchases: "Purchase Management",
            inventory: "Inventory",
            customers: "Customer",
            orders: "Orders",
            campaigns: "Campaign Management",
            shipments: "Shipment",
            reports: "Reports",
            "audit-logs": "Audit Logs"
        };
        const hrefs = {
            dashboard: "/index.html",
            suppliers: "/suppliers/index.html",
            products: "/products/index.html",
            warehouses: "/warehouses/index.html",
            purchases: "/purchases/index.html",
            inventory: "/inventory/index.html",
            customers: "/customers/index.html",
            orders: "/orders/index.html",
            campaigns: "/campaigns/index.html",
            shipments: "/shipments/index.html",
            reports: "/reports/index.html",
            "audit-logs": "/audit-logs/index.html"
        };
        return `<a href="${hrefs[key]}" class="btn secondary">${labels[key]}</a>`;
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
                <p>Hello <strong>${user ? user.username : 'User'}</strong>, your current role <strong>${roleObj.icon} ${roleObj.label}</strong> does not have permission to view or edit this module.</p>
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
