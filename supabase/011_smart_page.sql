-- Smarter building page with zero extra input from anyone:
-- next cleaning, usual cleaning days, visit log (from existing cleanings),
-- "me too" on open reports instead of duplicates, and "my reports" status per device.

alter table public.building_issues add column if not exists me_too int not null default 0;
create table if not exists public.building_issue_votes (
  issue_id uuid not null references public.building_issues on delete cascade,
  device_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (issue_id, device_id)
);
alter table public.building_issue_votes enable row level security;   -- no direct access; only via building_metoo

drop function if exists public.building_public(text, uuid, text);
create or replace function public.building_public(p_tag text, p_building uuid, p_key text, p_device uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b apartments; last tasks; nxt tasks; v_id uuid; ok boolean;
begin
  v_id := coalesce(p_building, (select building_id from nfc_tags where tag_id = p_tag));
  select * into b from apartments where id = v_id and kind = 'building' and deleted_at is null;
  if b.id is null then return null; end if;
  ok := coalesce(p_key, '') <> '' and exists (select 1 from building_tokens where building_id = b.id and resident_token = p_key);
  select * into last from tasks where apartment_id = b.id and status in ('submitted','approved') order by finished_at desc nulls last limit 1;
  select * into nxt from tasks where apartment_id = b.id and task_date >= fn_today() and status in ('pending','arrived','in_progress')
    and primary_cleaner is not null and coalesce(offer_status, 'none') in ('none','accepted') order by task_date, window_start limit 1;
  return json_build_object(
    'id', b.id, 'address', b.address, 'city', b.city, 'units_count', b.units_count,
    'status', b.connection_status, 'interest_count', b.interest_count,
    'has_committee', b.host_id is not null, 'committee_verified', b.committee_verified, 'verified', ok,
    'last_cleaning', case when last.id is null then null else json_build_object(
      'finished_at', last.finished_at, 'started_at', last.started_at, 'arrived_at', last.arrived_at,
      'photos', last.photos, 'checklist', last.checklist, 'approved', last.status = 'approved') end,
    'next_cleaning', case when nxt.id is null then null else json_build_object('date', nxt.task_date, 'from', nxt.window_start, 'to', nxt.window_end, 'status', nxt.status) end,
    'visits', coalesce((select json_agg(v order by v.finished_at desc) from (
        select finished_at, arrived_at, status = 'approved' as approved, photos->>'entrance' as photo,
               (select count(*) from jsonb_each(coalesce(checklist, '{}'::jsonb)) where value = 'true'::jsonb) as checks
        from tasks where apartment_id = b.id and status in ('submitted','approved') and finished_at is not null
        order by finished_at desc limit 6) v), '[]'::json),
    'pattern', coalesce((select json_agg(s order by s.dow) from (
        select extract(dow from finished_at at time zone 'Asia/Jerusalem')::int as dow, count(*) as n,
               round(avg(extract(hour from finished_at at time zone 'Asia/Jerusalem') + extract(minute from finished_at at time zone 'Asia/Jerusalem') / 60.0))::int as hour
        from tasks where apartment_id = b.id and status in ('submitted','approved') and finished_at > now() - interval '60 days'
        group by 1) s), '[]'::json),
    'receipts', case when ok then coalesce((select json_agg(r order by r.receipt_date desc) from (
        select id, title, vendor_name, amount, receipt_date, file_path from building_receipts where building_id = b.id order by receipt_date desc limit 30) r), '[]'::json) else '[]'::json end,
    'quotes', case when ok then coalesce((select json_agg(q order by q.status desc, q.created_at desc) from (
        select id, category, vendor_name, details, price, price_unit, status, is_group_deal, created_at from building_quotes where building_id = b.id) q), '[]'::json) else '[]'::json end,
    'open_issues', case when ok then coalesce((select json_agg(i order by i.me_too desc, i.created_at desc) from (
        select id, category, left(body, 160) as body, created_at, me_too,
               exists (select 1 from building_issue_votes vv where vv.issue_id = bi.id and vv.device_id = p_device) or bi.device_id = p_device as mine
        from building_issues bi where building_id = b.id and status = 'open' and created_at > now() - interval '21 days'
        order by me_too desc, created_at desc limit 12) i), '[]'::json) else '[]'::json end,
    'my_issues', case when ok and p_device is not null then coalesce((select json_agg(m order by m.created_at desc) from (
        select id, category, left(body, 100) as body, status, created_at, handled_at from building_issues
        where building_id = b.id and device_id = p_device and created_at > now() - interval '30 days' order by created_at desc limit 5) m), '[]'::json) else '[]'::json end
  );
end $$;

create or replace function public.building_metoo(p_building uuid, p_key text, p_issue uuid, p_device uuid) returns json
language plpgsql security definer set search_path = public as $$
declare n int; c int;
begin
  if not exists (select 1 from building_tokens where building_id = p_building and resident_token = p_key) then raise exception 'not verified'; end if;
  if not exists (select 1 from building_issues where id = p_issue and building_id = p_building and status = 'open') then raise exception 'not found'; end if;
  if exists (select 1 from building_issues where id = p_issue and device_id = p_device) then
    return json_build_object('me_too', (select me_too from building_issues where id = p_issue), 'counted', false); end if;
  insert into building_issue_votes(issue_id, device_id) values (p_issue, p_device) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then update building_issues set me_too = me_too + 1 where id = p_issue returning me_too into c;
  else select me_too into c from building_issues where id = p_issue; end if;
  return json_build_object('me_too', c, 'counted', n > 0);
end $$;

revoke execute on function public.building_public(text, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.building_metoo(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.building_public(text, uuid, text, uuid) to service_role;
grant execute on function public.building_metoo(uuid, text, uuid, uuid) to service_role;
