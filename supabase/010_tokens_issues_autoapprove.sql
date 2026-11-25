-- Stage 1+2: suppliers feed the building, committee receives; residents verified by a private invite link.

-- ── private links per building (kept out of the apartments row, so cleaners never read them)
create table if not exists public.building_tokens (
  building_id uuid primary key references public.apartments on delete cascade,
  resident_token text not null default replace(gen_random_uuid()::text, '-', ''),
  supplier_token text not null default replace(gen_random_uuid()::text, '-', ''),
  rotated_at timestamptz not null default now()
);
create unique index if not exists building_tokens_res on public.building_tokens(resident_token);
create unique index if not exists building_tokens_sup on public.building_tokens(supplier_token);
alter table public.building_tokens enable row level security;
drop policy if exists tokens_read on public.building_tokens;
create policy tokens_read on public.building_tokens for select to authenticated using (fn_manages_building(building_id));

create or replace function public.tg_building_tokens() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'building' then insert into building_tokens(building_id) values (new.id) on conflict do nothing; end if;
  return new;
end $$;
drop trigger if exists building_tokens_ins on public.apartments;
create trigger building_tokens_ins after insert or update of kind on public.apartments for each row execute function public.tg_building_tokens();
insert into public.building_tokens(building_id) select id from public.apartments where kind = 'building' on conflict do nothing;

create or replace function public.rotate_building_token(p_building uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not fn_manages_building(p_building) then raise exception 'רק ועד הבית יכול להחליף קישור'; end if;
  if p_kind = 'resident' then update building_tokens set resident_token = v, rotated_at = now() where building_id = p_building;
  elsif p_kind = 'supplier' then update building_tokens set supplier_token = v, rotated_at = now() where building_id = p_building;
  else raise exception 'bad kind'; end if;
  return v;
end $$;

-- ── "verified committee" badge: only the admin can set it
alter table public.apartments add column if not exists committee_verified boolean not null default false;
create or replace function public.tg_protect_verified() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if fn_is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.committee_verified := false;
  else
    new.committee_verified := old.committee_verified;
    if new.host_id is distinct from old.host_id then new.committee_verified := false; end if;
  end if;
  return new;
end $$;
drop trigger if exists protect_verified on public.apartments;
create trigger protect_verified before insert or update on public.apartments for each row execute function public.tg_protect_verified();

-- ── receipts: who sent them
alter table public.building_receipts add column if not exists source text not null default 'committee' check (source in ('committee','supplier','admin'));

-- ── resident reports
create table if not exists public.building_issues (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.apartments on delete cascade,
  category text not null check (category in ('cleaning','maintenance','other')),
  body text not null check (length(body) between 2 and 1000),
  device_id uuid,
  status text not null default 'open' check (status in ('open','handled')),
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create index if not exists building_issues_b on public.building_issues(building_id, created_at desc);
alter table public.building_issues enable row level security;
drop policy if exists issues_read on public.building_issues;
create policy issues_read on public.building_issues for select to authenticated using (
  fn_manages_building(building_id)
  or (category = 'cleaning' and exists (select 1 from apartments a where a.id = building_id and a.cleaner_id = auth.uid())));
drop policy if exists issues_update on public.building_issues;
create policy issues_update on public.building_issues for update to authenticated
  using (fn_manages_building(building_id)) with check (fn_manages_building(building_id));

-- ── public page (service role only): receipts/quotes and reporting only with the resident key
drop function if exists public.building_public(text, uuid);
create or replace function public.building_public(p_tag text, p_building uuid, p_key text) returns json
language plpgsql stable security definer set search_path = public as $$
declare b apartments; last tasks; v_id uuid; ok boolean;
begin
  v_id := coalesce(p_building, (select building_id from nfc_tags where tag_id = p_tag));
  select * into b from apartments where id = v_id and kind = 'building' and deleted_at is null;
  if b.id is null then return null; end if;
  ok := coalesce(p_key, '') <> '' and exists (select 1 from building_tokens where building_id = b.id and resident_token = p_key);
  select * into last from tasks where apartment_id = b.id and status in ('submitted','approved') order by finished_at desc nulls last limit 1;
  return json_build_object(
    'id', b.id, 'address', b.address, 'city', b.city, 'units_count', b.units_count,
    'status', b.connection_status, 'interest_count', b.interest_count,
    'has_committee', b.host_id is not null, 'committee_verified', b.committee_verified, 'verified', ok,
    'last_cleaning', case when last.id is null then null else json_build_object(
      'finished_at', last.finished_at, 'started_at', last.started_at, 'arrived_at', last.arrived_at,
      'photos', last.photos, 'checklist', last.checklist, 'approved', last.status = 'approved') end,
    'receipts', case when ok then coalesce((select json_agg(r order by r.receipt_date desc) from (
        select id, title, vendor_name, amount, receipt_date, file_path from building_receipts where building_id = b.id order by receipt_date desc limit 30) r), '[]'::json) else '[]'::json end,
    'quotes', case when ok then coalesce((select json_agg(q order by q.status desc, q.created_at desc) from (
        select id, category, vendor_name, details, price, price_unit, status, is_group_deal, created_at from building_quotes where building_id = b.id) q), '[]'::json) else '[]'::json end
  );
end $$;

create or replace function public.building_report(p_building uuid, p_key text, p_category text, p_body text, p_device uuid) returns json
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from building_tokens t join apartments a on a.id = t.building_id
                 where t.building_id = p_building and t.resident_token = p_key and a.deleted_at is null) then
    raise exception 'not verified'; end if;
  if p_category not in ('cleaning','maintenance','other') or length(coalesce(trim(p_body), '')) < 2 then raise exception 'bad input'; end if;
  select count(*) into n from building_issues where building_id = p_building and device_id = p_device and created_at > now() - interval '1 day';
  if n >= 5 then raise exception 'rate limit'; end if;
  select count(*) into n from building_issues where building_id = p_building and created_at > now() - interval '1 day';
  if n >= 40 then raise exception 'rate limit'; end if;
  insert into building_issues(building_id, category, body, device_id) values (p_building, p_category, left(trim(p_body), 1000), p_device);
  return json_build_object('ok', true);
end $$;

-- ── supplier link (service role only)
create or replace function public.supplier_info(p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('building_id', a.id, 'address', a.address, 'city', a.city)
  from building_tokens t join apartments a on a.id = t.building_id
  where t.supplier_token = p_token and a.deleted_at is null and coalesce(p_token, '') <> '';
$$;

create or replace function public.supplier_add_receipt(p_token text, p_title text, p_vendor text, p_amount numeric, p_date date, p_path text) returns uuid
language plpgsql security definer set search_path = public as $$
declare bid uuid; n int; v uuid;
begin
  select t.building_id into bid from building_tokens t join apartments a on a.id = t.building_id where t.supplier_token = p_token and a.deleted_at is null;
  if bid is null then raise exception 'bad token'; end if;
  if p_path is not null and p_path not like bid::text || '/%' then raise exception 'bad path'; end if;
  select count(*) into n from building_receipts where building_id = bid and source = 'supplier' and created_at > now() - interval '1 day';
  if n >= 40 then raise exception 'rate limit'; end if;
  insert into building_receipts(building_id, title, vendor_name, amount, receipt_date, file_path, source, created_by)
  values (bid, left(trim(p_title), 160), nullif(left(trim(coalesce(p_vendor, '')), 120), ''), p_amount, coalesce(p_date, (now() at time zone 'Asia/Jerusalem')::date), p_path, 'supplier', null)
  returning id into v;
  return v;
end $$;

revoke execute on function public.building_public(text, uuid, text) from public, anon, authenticated;
revoke execute on function public.building_report(uuid, text, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.supplier_info(text) from public, anon, authenticated;
revoke execute on function public.supplier_add_receipt(text, text, text, numeric, date, text) from public, anon, authenticated;
grant execute on function public.building_public(text, uuid, text) to service_role;
grant execute on function public.building_report(uuid, text, text, text, uuid) to service_role;
grant execute on function public.supplier_info(text) to service_role;
grant execute on function public.supplier_add_receipt(text, text, text, numeric, date, text) to service_role;
revoke execute on function public.rotate_building_token(uuid, text) from public, anon;
grant execute on function public.rotate_building_token(uuid, text) to authenticated;

-- ── automatic approval: 48h after the cleaning ended, unless a resident opened a cleaning report since
create or replace function public.auto_approve_building_cleanings() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update tasks t set status = 'approved', approved_at = now()
  from apartments a
  where a.id = t.apartment_id and a.kind = 'building' and t.status = 'submitted'
    and t.finished_at < now() - interval '48 hours'
    and not exists (select 1 from building_issues i where i.building_id = a.id and i.category = 'cleaning' and i.created_at >= t.finished_at);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.auto_approve_building_cleanings() from public, anon, authenticated;
select cron.unschedule('auto-approve-cleanings') where exists (select 1 from cron.job where jobname = 'auto-approve-cleanings');
select cron.schedule('auto-approve-cleanings', '17 * * * *', 'select public.auto_approve_building_cleanings()');
