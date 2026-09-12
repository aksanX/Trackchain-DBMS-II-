// TrackChain Dynamic Role-Based Access Control (RBAC) & Permission Engine
// Allows Admin to dynamically configure module permissions for each role and manage staff accounts.

const ROLES = {
    admin: {
        id: "admin",
        label: "Admin",
        icon: "",
        description: "Full system authority & access control matrix manager"
    },
    purchasing: {
        id: "purchasing",
        label: "Purchasing Officer",
        icon: "",
        description: "Sourcing, supplier management, product creation & purchase records"
    },
    marketing: {
        id: "marketing",
        label: "Marketing Manager",
        icon: "",
        description: "Campaign tracking, conversion analytics, customer list & storefront impact"
    },
    warehouse: {
        id: "warehouse",
        label: "Warehouse Manager",
        icon: "",
        description: "Hub capacity, stock transfers, product catalog & inventory levels"
    },
    shipment: {
        id: "shipment",
        label: "Shipment Manager",
        icon: "",
        description: "Order processing, tracking numbers, stock checks & status updates"
    }
};

const ALL_MODULE_KEYS = [
    { key: "dashboard",   label: "Dashboard Overview" },
    { key: "suppliers",   label: "Supplier Management" },
    { key: "products",    label: "Product Management" },
    { key: "warehouses",  label: "Warehouse" },
    { key: "purchases",   label: "Purchase Management" },
    { key: "inventory",   label: "Inventory" },
    { key: "customers",   label: "Customer" },
    { key: "orders",      label: "Orders" },
    { key: "campaigns",   label: "Campaign Management" },
    { key: "shipments",   label: "Shipment" },
    { key: "reports",     label: "Reports" },
    { key: "audit-logs",  label: "Audit Logs" },
    { key: "permissions", label: "Access Control" }
];

const DEFAULT_PERMISSIONS_MATRIX = {
    purchasing: ["dashboard", "suppliers", "products", "purchases", "inventory", "reports"],
    marketing:  ["dashboard", "campaigns", "customers", "reports"],
    warehouse:  ["dashboard", "products", "warehouses", "inventory", "reports"],
    shipment:   ["dashboard", "inventory", "orders", "shipments", "reports"]
};

const DEFAULT_STAFF_ACCOUNTS = [
    { username: "admin",      password: "123", name: "Alex Admin",       roleId: "admin",      active: true },
    { username: "purchasing", password: "123", name: "Sarah Purchasing",  roleId: "purchasing", active: true },
    { username: "marketing",  password: "123", name: "Marcus Marketing", roleId: "marketing",  active: true },
    { username: "warehouse",  password: "123", name: "David Warehouse",  roleId: "warehouse",  active: true },
    { username: "shipment",   password: "123", name: "Elena Shipment",   roleId: "shipment",   active: true }
];

const STORAGE_KEYS = {
    session: "trackchain_session_user",
    matrix:  "trackchain_rbac_matrix_v2",
    staff:   "trackchain_staff_accounts_v2"
};

// ---- RBAC Matrix Methods ----

function getRolePermissionsMatrix() {
    const raw = localStorage.getItem(STORAGE_KEYS.matrix);
    if (!raw) return JSON.parse(JSON.stringify(DEFAULT_PERMISSIONS_MATRIX));
    try {
        return JSON.parse(raw);
    } catch (e) {
        return JSON.parse(JSON.stringify(DEFAULT_PERMISSIONS_MATRIX));
    }
}

function saveRolePermissionsMatrix(matrix) {
    localStorage.setItem(STORAGE_KEYS.matrix, JSON.stringify(matrix));
}

function resetPermissionsMatrix() {
    localStorage.removeItem(STORAGE_KEYS.matrix);
}

function canRoleAccess(roleId, pageKey) {
    if (roleId === "admin") return true; // Admin always has full access
    const matrix = getRolePermissionsMatrix();
    const allowed = matrix[roleId] || [];
    return allowed.includes(pageKey);
}

// ---- Staff Account Methods ----

function getStaffAccounts() {
    const raw = localStorage.getItem(STORAGE_KEYS.staff);
    if (!raw) return JSON.parse(JSON.stringify(DEFAULT_STAFF_ACCOUNTS));
    try {
        return JSON.parse(raw);
    } catch (e) {
        return JSON.parse(JSON.stringify(DEFAULT_STAFF_ACCOUNTS));
    }
}

function saveStaffAccounts(accounts) {
    localStorage.setItem(STORAGE_KEYS.staff, JSON.stringify(accounts));
}

function createStaffAccount(username, password, name, roleId) {
    const accounts = getStaffAccounts();
    const cleanUser = (username || "").trim().toLowerCase();

    if (accounts.some(acc => acc.username.toLowerCase() === cleanUser)) {
        return { success: false, message: "Username already exists." };
    }

    accounts.push({
        username: cleanUser,
        password: password.trim(),
        name: name.trim(),
        roleId: roleId,
        active: true
    });

    saveStaffAccounts(accounts);
    return { success: true };
}

function toggleStaffAccountStatus(username) {
    const accounts = getStaffAccounts();
    const target = accounts.find(acc => acc.username.toLowerCase() === username.toLowerCase());
    if (target) {
        target.active = !target.active;
        saveStaffAccounts(accounts);
    }
}

// ---- Authentication & Session Engine ----

function getLoggedInUser() {
    const raw = localStorage.getItem(STORAGE_KEYS.session) || sessionStorage.getItem(STORAGE_KEYS.session);
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

    const accounts = getStaffAccounts();
    const account = accounts.find(
        acc => acc.username.toLowerCase() === cleanUser && acc.password === cleanPass
    );

    if (!account) {
        return { success: false, message: "Invalid username or password. Please try again." };
    }

    if (!account.active) {
        return { success: false, message: "This account has been deactivated by the Administrator." };
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
    localStorage.removeItem(STORAGE_KEYS.session);
    sessionStorage.removeItem(STORAGE_KEYS.session);
    storage.setItem(STORAGE_KEYS.session, JSON.stringify(userSession));

    return { success: true };
}

function logout() {
    localStorage.removeItem(STORAGE_KEYS.session);
    sessionStorage.removeItem(STORAGE_KEYS.session);
    window.location.href = "/login/index.html";
}

function checkPageAccess(pageKey) {
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
                <span class="user-role-badge">${roleObj ? roleObj.label : user.roleId}</span>
            </div>
            <button type="button" class="btn-logout" onclick="logout()" title="Log out of session">
                Log Out
            </button>
        </div>
    `;
}

function renderAccessRestrictedPage(pageKey, activeRole) {
    const main = document.querySelector(".shell-main") || document.body;
    const roleObj = ROLES[activeRole] || ROLES.admin;
    const user = getLoggedInUser();
    const matrix = getRolePermissionsMatrix();
    const allowedKeys = activeRole === "admin" ? ALL_MODULE_KEYS.map(m => m.key) : (matrix[activeRole] || []);

    const allowedModulesHtml = allowedKeys.map(key => {
        const found = ALL_MODULE_KEYS.find(m => m.key === key);
        const label = found ? found.label : key;
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
            "audit-logs": "/audit-logs/index.html",
            permissions: "/admin/permissions.html"
        };
        return `<a href="${hrefs[key]}" class="btn secondary">${label}</a>`;
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
                <h2>Module Access Restricted</h2>
                <p>Hello <strong>${user ? user.username : 'User'}</strong>, your current role <strong>${roleObj.label}</strong> does not have permission to view or edit this module.</p>
                <p class="role-desc-sub">${roleObj.description}</p>
                <div class="access-restricted-actions">
                    <p><strong>Available modules for your role:</strong></p>
                    <div style="display: flex; gap: 8px; flex-wrap: wrap; margin-top: 12px; justify-content: center;">
                        ${allowedModulesHtml || '<em>No modules assigned</em>'}
                    </div>
                </div>
            </div>
        </main>
    `;

    renderUserHeaderProfile();
}
