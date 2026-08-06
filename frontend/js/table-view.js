// Shared table engine: search box + click-to-sort headers + CSV export,
// all driven by a plain array of flat row objects. Extracted from the
// Warehouse page's page-local version so Supplier/Product/Purchase
// Management can reuse the exact same behavior instead of re-implementing
// it three times. (The Warehouse page keeps its own local copy untouched.)

function animateCount(el, target) {
    const duration = 550;
    const start = performance.now();
    function tick(now) {
        const t = Math.min(1, (now - start) / duration);
        const eased = 1 - Math.pow(1 - t, 3);
        el.textContent = Math.round(target * eased).toLocaleString();
        if (t < 1) requestAnimationFrame(tick);
        else el.textContent = target.toLocaleString();
    }
    requestAnimationFrame(tick);
}

function slug(s, fallback) {
    const base = fallback || "export";
    return (s || base).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || base;
}

function csvCell(v) {
    const s = (v === null || v === undefined) ? "" : String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function downloadCsv(filename, headers, rows) {
    const lines = [headers.map(csvCell).join(",")];
    rows.forEach(r => lines.push(r.map(csvCell).join(",")));
    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// cfg: { tableId, searchId, exportId, colspan, searchFields[], emptyMsg,
//        noMatchMsg, rowHtml(r), afterRender(), csvName(), csvHeaders[], csvRow(r) }
function createTableView(cfg) {
    const state = { q: "", key: null, dir: 1, raw: [], view: [] };

    function apply() {
        let rows = state.raw;
        if (state.q) {
            rows = rows.filter(r => cfg.searchFields.some(f =>
                String(r[f] ?? "").toLowerCase().includes(state.q)));
        }
        if (state.key) {
            rows = [...rows].sort((a, b) => {
                let x = a[state.key], y = b[state.key];
                if (typeof x === "string") x = x.toLowerCase();
                if (typeof y === "string") y = y.toLowerCase();
                if (x === undefined || x === null) return 1;
                if (y === undefined || y === null) return -1;
                if (x < y) return -1 * state.dir;
                if (x > y) return 1 * state.dir;
                return 0;
            });
        }
        state.view = rows;
        fillTable(cfg.tableId, rows, cfg.rowHtml, cfg.colspan);
        if (!rows.length) {
            // FIX: a search with zero matches on a non-empty table used to
            // reuse the "table is genuinely empty" message, which is
            // misleading -- "No suppliers yet" when there are 40 suppliers
            // and the search just didn't match any of them.
            const msg = (state.raw.length > 0 && cfg.noMatchMsg) ? cfg.noMatchMsg : cfg.emptyMsg;
            if (msg) {
                const cell = document.querySelector(`#${cfg.tableId} tbody td`);
                if (cell) cell.textContent = msg;
            }
        }
        if (cfg.afterRender) cfg.afterRender();
    }

    if (cfg.searchId) {
        const inp = document.getElementById(cfg.searchId);
        // FIX: re-filtering on every single keystroke is harmless at small
        // table sizes, but a 150ms debounce keeps typing smooth once a
        // table (e.g. purchase history) grows into the hundreds of rows.
        let debounceTimer = null;
        if (inp) inp.addEventListener("input", e => {
            const value = e.target.value;
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                state.q = value.trim().toLowerCase();
                apply();
            }, 150);
        });
    }

    const ths = document.querySelectorAll(`#${cfg.tableId} thead th[data-key]`);
    ths.forEach(th => th.addEventListener("click", () => {
        const k = th.dataset.key;
        if (state.key === k) state.dir *= -1; else { state.key = k; state.dir = 1; }
        ths.forEach(t => t.removeAttribute("data-dir"));
        th.setAttribute("data-dir", state.dir === 1 ? "asc" : "desc");
        apply();
    }));

    if (cfg.exportId) {
        const btn = document.getElementById(cfg.exportId);
        if (btn) btn.addEventListener("click", () => {
            if (!state.view.length) return;
            downloadCsv(cfg.csvName(), cfg.csvHeaders, state.view.map(cfg.csvRow));
        });
    }

    return {
        setRaw(rows) { state.raw = rows || []; apply(); },
        getView() { return state.view; },
        loading() {
            const tb = document.querySelector(`#${cfg.tableId} tbody`);
            if (tb) tb.innerHTML = `<tr><td colspan="${cfg.colspan}" class="tbl-loading">Loading…</td></tr>`;
        }
    };
}
