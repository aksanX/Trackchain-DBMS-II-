// Admin-only staff provisioning.
//
// Why this has to be an edge function: creating/deleting a Supabase Auth
// user requires the service role key, which must never reach the browser
// (it bypasses RLS entirely -- anyone with it owns the whole database).
// This function holds that key server-side, checks the caller is an
// active admin (via staff_profiles), and only then acts on their behalf.
//
// Deploy: supabase functions deploy admin-manage-staff
// Called from: frontend/staff/index.html

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const VALID_ROLES = ["admin", "purchasing", "marketing", "warehouse", "shipment"];

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Missing Authorization header" }, 401);

    // Client scoped to the caller's own token -- used only to find out who they are.
    const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
        global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: { user: caller }, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !caller) return json({ error: "Invalid or expired session" }, 401);

    // Privileged client -- bypasses RLS, only used after the admin check below.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: callerProfile } = await admin
        .from("staff_profiles")
        .select("role, is_active")
        .eq("id", caller.id)
        .single();

    if (!callerProfile || !callerProfile.is_active || callerProfile.role !== "admin") {
        return json({ error: "Admin access required" }, 403);
    }

    let body: Record<string, unknown>;
    try {
        body = await req.json();
    } catch {
        return json({ error: "Invalid JSON body" }, 400);
    }
    const action = body.action;

    if (action === "list") {
        const { data, error } = await admin
            .from("staff_profiles")
            .select("id, email, full_name, role, is_active, created_at")
            .order("created_at", { ascending: true });
        if (error) return json({ error: error.message }, 500);
        return json({ staff: data });
    }

    if (action === "create") {
        const email = String(body.email || "").trim().toLowerCase();
        const password = String(body.password || "");
        const fullName = String(body.full_name || "").trim();
        const role = String(body.role || "");

        if (!email || !password || !fullName) return json({ error: "email, password and full_name are required" }, 400);
        if (password.length < 6) return json({ error: "Password must be at least 6 characters" }, 400);
        if (!VALID_ROLES.includes(role)) return json({ error: `role must be one of ${VALID_ROLES.join(", ")}` }, 400);

        const { data: created, error: createErr } = await admin.auth.admin.createUser({
            email,
            password,
            email_confirm: true,
        });
        if (createErr || !created.user) return json({ error: createErr?.message || "Could not create the auth user" }, 400);

        const { error: profileErr } = await admin.from("staff_profiles").insert({
            id: created.user.id,
            email,
            full_name: fullName,
            role,
            is_active: true,
            created_by: caller.id,
        });
        if (profileErr) {
            // Roll back the orphaned auth user so a failed insert doesn't leave a login with no role.
            await admin.auth.admin.deleteUser(created.user.id);
            return json({ error: profileErr.message }, 500);
        }

        return json({ success: true, id: created.user.id });
    }

    if (action === "set_active") {
        const id = String(body.id || "");
        const isActive = Boolean(body.is_active);
        if (!id) return json({ error: "id is required" }, 400);

        if (!isActive) {
            const guard = await guardLastActiveAdmin(admin, id);
            if (guard) return json({ error: guard }, 400);
        }

        const { error } = await admin.from("staff_profiles").update({ is_active: isActive }).eq("id", id);
        if (error) return json({ error: error.message }, 500);
        return json({ success: true });
    }

    if (action === "delete") {
        const id = String(body.id || "");
        if (!id) return json({ error: "id is required" }, 400);
        if (id === caller.id) return json({ error: "You cannot delete your own account" }, 400);

        const guard = await guardLastActiveAdmin(admin, id);
        if (guard) return json({ error: guard }, 400);

        const { error: delProfileErr } = await admin.from("staff_profiles").delete().eq("id", id);
        if (delProfileErr) return json({ error: delProfileErr.message }, 500);

        await admin.auth.admin.deleteUser(id);
        return json({ success: true });
    }

    return json({ error: `Unknown action: ${action}` }, 400);
});

// Refuses to deactivate/delete a target if they're the last active admin.
async function guardLastActiveAdmin(
    admin: ReturnType<typeof createClient>,
    targetId: string,
): Promise<string | null> {
    const { data: target } = await admin.from("staff_profiles").select("role, is_active").eq("id", targetId).single();
    if (!target || target.role !== "admin" || !target.is_active) return null;

    const { count } = await admin
        .from("staff_profiles")
        .select("id", { count: "exact", head: true })
        .eq("role", "admin")
        .eq("is_active", true);

    if ((count ?? 0) <= 1) return "Cannot remove the last active admin";
    return null;
}
