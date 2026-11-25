// CleanEilat — public building page (no sign-in).
// GET  ?t=<tagId> | ?b=<buildingId> [&key=<residentKey>]  → building data; receipts/quotes only with a valid resident key
// POST {action:'vote', building_id, device_id}                → "I'm interested" (one per device)
// POST {action:'report', building_id, key, category, body, device_id} → resident report (verified residents only)
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TAG = /^[A-Za-z0-9_-]{2,40}$/;
const KEY = /^[0-9a-f]{32}$/i;
const TTL = 60 * 60;

async function sign(bucket: string, paths: string[]): Promise<Record<string, string>> {
  const clean = [...new Set(paths.filter((p) => typeof p === "string" && p && !p.includes("..")))];
  if (!clean.length) return {};
  const { data } = await db.storage.from(bucket).createSignedUrls(clean, TTL);
  const out: Record<string, string> = {};
  for (const r of data || []) if (r.signedUrl && r.path) out[r.path] = r.signedUrl;
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  if (req.method === "POST") {
    const body = await req.json().catch(() => ({}));
    if (!UUID.test(body.building_id || "") || !UUID.test(body.device_id || "")) return json({ error: "bad request" }, 400);
    if (body.action === "report") {
      if (!KEY.test(body.key || "")) return json({ error: "not verified" }, 403);
      const { data, error } = await db.rpc("building_report", {
        p_building: body.building_id, p_key: body.key, p_category: String(body.category || ""),
        p_body: String(body.body || "").slice(0, 1000), p_device: body.device_id,
      });
      if (error) {
        const m = error.message || "";
        return json({ error: m.includes("rate limit") ? "rate limit" : m.includes("not verified") ? "not verified" : "bad input" },
          m.includes("rate limit") ? 429 : m.includes("not verified") ? 403 : 400);
      }
      return json(data);
    }
    const { data, error } = await db.rpc("building_vote", { p_building: body.building_id, p_device: body.device_id });
    if (error) return json({ error: "not found" }, 404);
    return json(data);
  }

  const url = new URL(req.url);
  const t = url.searchParams.get("t"), b = url.searchParams.get("b"), key = url.searchParams.get("key");
  if (t && !TAG.test(t)) return json({ error: "bad tag" }, 400);
  if (b && !UUID.test(b)) return json({ error: "bad id" }, 400);
  if (!t && !b) return json({ error: "missing" }, 400);

  const { data, error } = await db.rpc("building_public", { p_tag: t || null, p_building: b || null, p_key: key && KEY.test(key) ? key : null });
  if (error) return json({ error: "server" }, 500);
  if (!data) return json({ error: "not found" }, 404);

  const lc = data.last_cleaning;
  if (lc?.photos) {
    const links = await sign("task-photos", Object.values(lc.photos) as string[]);
    lc.photos = Object.fromEntries(Object.entries(lc.photos).map(([k, p]) => [k, links[p as string] || null]));
  }
  const rlinks = await sign("building-docs", data.receipts.map((r: { file_path: string }) => r.file_path));
  data.receipts = data.receipts.map((r: { file_path: string }) => ({ ...r, file_url: r.file_path ? rlinks[r.file_path] || null : null, file_path: undefined }));
  return json(data);
});
