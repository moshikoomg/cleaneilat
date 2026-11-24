// CleanEilat — Airbnb / Booking calendar sync
// Pulls each apartment's iCal feed, creates a cleaning on every checkout date,
// moves cleanings when a booking changes, and cancels unassigned ones when a booking disappears.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Ev = { uid: string; summary: string; end: string };

// iCal date → YYYY-MM-DD (Israel time for timestamps)
function icsDate(v: string): string | null {
  const m = v.match(/(\d{4})(\d{2})(\d{2})(T(\d{2})(\d{2})(\d{2})(Z)?)?/);
  if (!m) return null;
  if (!m[4]) return `${m[1]}-${m[2]}-${m[3]}`;
  if (m[8]) {
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[5], +m[6], +m[7]));
    return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jerusalem" }).format(d);
  }
  return `${m[1]}-${m[2]}-${m[3]}`;
}

export function parseIcs(text: string): Ev[] {
  const lines = text.replace(/\r\n[ \t]/g, "").replace(/\n[ \t]/g, "").split(/\r?\n/);
  const out: Ev[] = [];
  let cur: Record<string, string> | null = null;
  for (const line of lines) {
    if (line === "BEGIN:VEVENT") { cur = {}; continue; }
    if (line === "END:VEVENT") {
      if (cur && cur.DTEND) {
        const end = icsDate(cur.DTEND);
        if (end) out.push({ uid: cur.UID || `${cur.DTSTART}-${cur.DTEND}`, summary: cur.SUMMARY || "", end });
      }
      cur = null; continue;
    }
    if (!cur) continue;
    const i = line.indexOf(":");
    if (i < 0) continue;
    const key = line.slice(0, i).split(";")[0].toUpperCase();
    cur[key] = line.slice(i + 1).trim();
  }
  return out;
}

const isBlock = (s: string) => /not available|blocked|closed|unavailable/i.test(s);

type Caller = { kind: "cron" | "admin" | "host"; uid?: string } | null;

async function authorize(req: Request): Promise<Caller> {
  const cron = req.headers.get("x-cron-key");
  if (cron) {
    const { data } = await db.from("app_secrets").select("value").eq("name", "cron_key").single();
    return !!data && data.value === cron ? { kind: "cron" } : null;
  }
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data: u } = await db.auth.getUser(token);
  if (!u?.user) return null;
  const { data: p } = await db.from("profiles").select("role,status").eq("id", u.user.id).single();
  if (p?.role === "admin") return { kind: "admin", uid: u.user.id };
  if (p?.role === "host" && p?.status === "approved") return { kind: "host", uid: u.user.id };
  return null;
}

// only public https calendar links: no IP literals, no local names
function safeUrl(raw: string): boolean {
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:") return false;
    const h = u.hostname.toLowerCase();
    if (!h.includes(".") || h.endsWith(".local") || h.endsWith(".internal") || h === "localhost") return false;
    if (/^[\d.]+$/.test(h) || h.includes(":")) return false;
    return true;
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const caller = await authorize(req);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const body = await req.json().catch(() => ({}));
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Jerusalem" }).format(new Date());
  const horizon = new Date(today + "T12:00:00Z");
  horizon.setUTCDate(horizon.getUTCDate() + 90);
  const until = horizon.toISOString().slice(0, 10);

  let q = db.from("apartments").select("id,name,ical_url").not("ical_url", "is", null).eq("active", true).is("deleted_at", null);
  if (body.apartment_id) q = q.eq("id", body.apartment_id);
  if (caller.kind === "host") q = q.eq("host_id", caller.uid!);
  const { data: aps, error } = await q;
  if (error) return json({ error: error.message }, 500);

  const report = { apartments: 0, created: 0, moved: 0, cancelled: 0, errors: [] as string[] };
  for (const ap of aps || []) {
    report.apartments++;
    try {
      if (!safeUrl(ap.ical_url)) throw new Error("קישור היומן לא תקין. צריך קישור https מ-Airbnb או Booking");
      const res = await fetch(ap.ical_url, { headers: { "User-Agent": "CleanEilat-Sync/1.0" } });
      if (!res.ok) throw new Error(`היומן החזיר שגיאה ${res.status}`);
      const text = await res.text();
      if (!text.includes("BEGIN:VCALENDAR")) throw new Error("הקישור לא מחזיר יומן iCal");
      const evs = parseIcs(text).filter((e) => !isBlock(e.summary) && e.end >= today && e.end <= until);

      const { data: existing } = await db.from("tasks")
        .select("id,booking_uid,task_date,status,primary_cleaner")
        .eq("apartment_id", ap.id).eq("source", "ical").gte("task_date", today);
      const byUid = new Map((existing || []).map((t) => [t.booking_uid, t]));
      const seen = new Set<string>();

      for (const e of evs) {
        seen.add(e.uid);
        const t = byUid.get(e.uid);
        if (!t) {
          const { error: ie } = await db.from("tasks").insert({
            apartment_id: ap.id, task_date: e.end, source: "ical", booking_uid: e.uid, status: "pending",
          });
          if (!ie) report.created++;
        } else if (t.task_date !== e.end && ["pending", "requested", "cancelled"].includes(t.status)) {
          // the date changed: the cleaner has to confirm the new date again
          await db.from("tasks").update({ task_date: e.end, status: "pending", ...(t.primary_cleaner ? { offer_status: "offered" } : {}) }).eq("id", t.id);
          report.moved++;
        } else if (t.status === "cancelled") {
          await db.from("tasks").update({ status: "pending" }).eq("id", t.id);
        }
      }
      for (const t of existing || []) {
        if (!seen.has(t.booking_uid) && t.status === "pending") {
          await db.from("tasks").update({ status: "cancelled" }).eq("id", t.id);
          report.cancelled++;
        }
      }
      await db.from("apartments").update({ ical_synced_at: new Date().toISOString(), ical_error: null }).eq("id", ap.id);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      report.errors.push(`${ap.name}: ${msg}`);
      await db.from("apartments").update({ ical_error: msg }).eq("id", ap.id);
    }
  }
  return json(report);
});
