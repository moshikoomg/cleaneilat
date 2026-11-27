// ועדלי — super admin tools. Only profiles.is_super may call it. Every action is written to admin_audit.
// POST {action:'impersonate', user_id}                       → one-time token_hash to open a session as that user (in a separate tab)
// POST {action:'create_user', email, full_name, phone, role} → pre-creates the account; Google sign-in with that email joins it
// POST {action:'block', user_id, on}                         → ban / unban sign-in
// POST {action:'delete_user', user_id}                       → deletes the account (only when it has no history; otherwise use block)
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: who } = await db.auth.getUser(jwt);
  if (!who?.user) return json({ error: "unauthorized" }, 401);
  const { data: me } = await db.from("profiles").select("id, is_super, blocked_at").eq("id", who.user.id).single();
  if (!me?.is_super || me.blocked_at) return json({ error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({}));
  const audit = (action: string, target: string | null, detail: Record<string, unknown> = {}) =>
    db.from("admin_audit").insert({ admin_id: me.id, action, target_user: target, detail });

  const target = async () => {
    if (!UUID.test(body.user_id || "")) return null;
    const { data } = await db.from("profiles").select("id, email, full_name, role, is_super").eq("id", body.user_id).single();
    return data;
  };

  if (body.action === "impersonate") {
    const t = await target();
    if (!t?.email) return json({ error: "not found" }, 404);
    if (t.id === me.id) return json({ error: "self" }, 400);
    const { data, error } = await db.auth.admin.generateLink({ type: "magiclink", email: t.email });
    if (error || !data?.properties?.hashed_token) return json({ error: "link failed" }, 500);
    await audit("impersonate", t.id, { name: t.full_name });
    return json({ token_hash: data.properties.hashed_token, name: t.full_name, role: t.role });
  }

  if (body.action === "create_user") {
    const email = String(body.email || "").trim().toLowerCase();
    const role = ["host", "cleaner", "admin"].includes(body.role) ? body.role : null;
    if (!EMAIL.test(email) || !role) return json({ error: "bad input" }, 400);
    const full_name = String(body.full_name || "").slice(0, 80) || null;
    const { data, error } = await db.auth.admin.createUser({ email, email_confirm: true, user_metadata: { full_name } });
    if (error) return json({ error: /already/i.test(error.message) ? "exists" : "create failed" }, /already/i.test(error.message) ? 409 : 500);
    const id = data.user.id;
    const patch: Record<string, unknown> = { role, status: "approved", full_name, phone: String(body.phone || "").slice(0, 20) || null };
    if (role === "host") patch.onboarding = { kind: "committee" };
    if (role !== "admin") patch.desired_role = role;
    await db.from("profiles").update(patch).eq("id", id);
    await audit("create_user", id, { email, role });
    return json({ id });
  }

  if (body.action === "block") {
    const t = await target();
    if (!t) return json({ error: "not found" }, 404);
    if (t.is_super) return json({ error: "forbidden" }, 403);
    const on = !!body.on;
    const { error } = await db.auth.admin.updateUserById(t.id, { ban_duration: on ? "876000h" : "none" });
    if (error) return json({ error: "ban failed" }, 500);
    await db.from("profiles").update({ blocked_at: on ? new Date().toISOString() : null }).eq("id", t.id);
    await audit(on ? "block" : "unblock", t.id, { name: t.full_name });
    return json({ ok: true });
  }

  if (body.action === "delete_user") {
    const t = await target();
    if (!t) return json({ error: "not found" }, 404);
    if (t.is_super || t.id === me.id) return json({ error: "forbidden" }, 403);
    const { error } = await db.auth.admin.deleteUser(t.id);
    if (error) return json({ error: "has history" }, 409);
    await audit("delete_user", null, { id: t.id, name: t.full_name, email: t.email });
    return json({ ok: true });
  }

  return json({ error: "unknown action" }, 400);
});
