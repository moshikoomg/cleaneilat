// CleanEilat — supplier upload link (no sign-in).
// GET  ?s=<supplierToken>                → which building this link belongs to
// POST multipart: s, title, vendor, amount, date, file → receipt goes straight into the building's drawer
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

const TOKEN = /^[0-9a-f]{32}$/i;
const MAX = 10 * 1024 * 1024;
const TYPES: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  if (req.method === "GET") {
    const s = new URL(req.url).searchParams.get("s") || "";
    if (!TOKEN.test(s)) return json({ error: "bad link" }, 404);
    const { data } = await db.rpc("supplier_info", { p_token: s });
    return data ? json(data) : json({ error: "bad link" }, 404);
  }

  if (req.method !== "POST") return json({ error: "method" }, 405);
  const form = await req.formData().catch(() => null);
  if (!form) return json({ error: "bad request" }, 400);
  const s = String(form.get("s") || "");
  if (!TOKEN.test(s)) return json({ error: "bad link" }, 404);
  const { data: info } = await db.rpc("supplier_info", { p_token: s });
  if (!info) return json({ error: "bad link" }, 404);

  const title = String(form.get("title") || "").trim();
  if (title.length < 2 || title.length > 160) return json({ error: "חסר תיאור" }, 400);
  const amountRaw = String(form.get("amount") || "").trim();
  const amount = amountRaw === "" ? null : Number(amountRaw);
  if (amount !== null && (!Number.isFinite(amount) || amount < 0 || amount > 10_000_000)) return json({ error: "סכום לא תקין" }, 400);
  const dateRaw = String(form.get("date") || "");
  const date = /^\d{4}-\d{2}-\d{2}$/.test(dateRaw) ? dateRaw : null;

  let path: string | null = null;
  const file = form.get("file");
  if (file && typeof file !== "string" && file.size > 0) {
    const ext = TYPES[file.type];
    if (!ext) return json({ error: "אפשר להעלות תמונה או PDF" }, 400);
    if (file.size > MAX) return json({ error: "הקובץ גדול מ-10MB" }, 400);
    path = `${info.building_id}/sup-${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
    const { error: ue } = await db.storage.from("building-docs").upload(path, file, { contentType: file.type, upsert: false });
    if (ue) return json({ error: "ההעלאה נכשלה, נסו שוב" }, 500);
  } else {
    return json({ error: "צריך לצרף צילום של הקבלה" }, 400);
  }

  const { data, error } = await db.rpc("supplier_add_receipt", {
    p_token: s, p_title: title, p_vendor: String(form.get("vendor") || ""), p_amount: amount, p_date: date, p_path: path,
  });
  if (error) {
    if (path) await db.storage.from("building-docs").remove([path]);
    return json({ error: (error.message || "").includes("rate limit") ? "יותר מדי העלאות היום" : "השמירה נכשלה" }, error.message?.includes("rate limit") ? 429 : 400);
  }
  return json({ ok: true, id: data });
});
