-- Buildings module: residential buildings / house committees, as a layer on top of the existing
-- properties (apartments), cleanings (tasks), photos and permissions.

-- 1. property type
alter table public.apartments
  add column if not exists kind text not null default 'vacation' check (kind in ('vacation','building')),
  add column if not exists city text,
  add column if not exists units_count int check (units_count is null or units_count between 1 and 2000),
  add column if not exists connection_status text not null default 'active' check (connection_status in ('active','pending_interest')),
  add column if not exists interest_count int not null default 0;

-- 2. NFC / QR tags
create table if not exists public.nfc_tags (
  tag_id text primary key check (tag_id ~ '^[A-Za-z0-9_-]{2,40}$'),
  building_id uuid not null references public.apartments on delete cascade,
  locked boolean not null default false,
  written_by uuid references public.profiles default auth.uid(),
  written_at timestamptz not null default now()
);
create index if not exists nfc_tags_building on public.nfc_tags(building_id);

-- one vote per device per building (the device id is a random id kept in the browser)
create table if not exists public.building_interest (
  building_id uuid not null references public.apartments on delete cascade,
  device_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (building_id, device_id)
);

-- 3. quotes and receipts
create table if not exists public.building_quotes (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.apartments on delete cascade,
  category text not null check (category in ('cleaning','elevator','gardening','maintenance','other')),
  vendor_name text not null check (length(vendor_name) between 1 and 120),
  details text check (length(details) <= 2000),
  price numeric not null check (price >= 0),
  price_unit text not null default 'month' check (price_unit in ('month','once')),
  status text not null default 'open' check (status in ('open','selected')),
  is_group_deal boolean not null default false,
  created_by uuid references public.profiles default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists building_quotes_b on public.building_quotes(building_id);

create table if not exists public.building_receipts (
  id uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.apartments on delete cascade,
  title text not null check (length(title) between 1 and 160),
  vendor_name text,
  amount numeric check (amount is null or amount >= 0),
  receipt_date date not null default ((now() at time zone 'Asia/Jerusalem')::date),
  file_path text,
  created_by uuid references public.profiles default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists building_receipts_b on public.building_receipts(building_id);

-- who manages a building: admin, or the committee account set as the building's host
create or replace function public.fn_manages_building(p_building uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select fn_is_admin() or exists (select 1 from apartments where id = p_building and kind = 'building' and host_id = auth.uid() and deleted_at is null);
$$;

alter table public.nfc_tags enable row level security;
alter table public.building_interest enable row level security;
alter table public.building_quotes enable row level security;
alter table public.building_receipts enable row level security;

drop policy if exists nfc_admin on public.nfc_tags;
create policy nfc_admin on public.nfc_tags for all to authenticated using (fn_is_admin()) with check (fn_is_admin());
-- building_interest: no direct access at all (only through building_vote, called by the public edge function)
drop policy if exists quotes_manage on public.building_quotes;
create policy quotes_manage on public.building_quotes for all to authenticated
  using (fn_manages_building(building_id)) with check (fn_manages_building(building_id));
drop policy if exists receipts_manage on public.building_receipts;
create policy receipts_manage on public.building_receipts for all to authenticated
  using (fn_manages_building(building_id)) with check (fn_manages_building(building_id));

-- private bucket for receipt files: <building_id>/<file>
insert into storage.buckets (id, name, public) values ('building-docs', 'building-docs', false) on conflict (id) do nothing;
drop policy if exists bdocs_rw on storage.objects;
create policy bdocs_rw on storage.objects for all to authenticated
  using (bucket_id = 'building-docs' and fn_manages_building(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'building-docs' and fn_manages_building(((storage.foldername(name))[1])::uuid));

-- 4. public data for the building page (called only by the edge function with the service role)
create or replace function public.building_public(p_tag text, p_building uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b apartments; last tasks; v_id uuid;
begin
  v_id := coalesce(p_building, (select building_id from nfc_tags where tag_id = p_tag));
  select * into b from apartments where id = v_id and kind = 'building' and deleted_at is null;
  if b.id is null then return null; end if;
  select * into last from tasks where apartment_id = b.id and status in ('submitted','approved') order by finished_at desc nulls last limit 1;
  return json_build_object(
    'id', b.id, 'address', b.address, 'city', b.city, 'units_count', b.units_count,
    'status', b.connection_status, 'interest_count', b.interest_count,
    'last_cleaning', case when last.id is null then null else json_build_object(
      'finished_at', last.finished_at, 'started_at', last.started_at, 'arrived_at', last.arrived_at,
      'photos', last.photos, 'checklist', last.checklist, 'approved', last.status = 'approved') end,
    'receipts', coalesce((select json_agg(r order by r.receipt_date desc) from (
        select id, title, vendor_name, amount, receipt_date, file_path from building_receipts where building_id = b.id order by receipt_date desc limit 10) r), '[]'::json),
    'quotes', coalesce((select json_agg(q order by q.status desc, q.created_at desc) from (
        select id, category, vendor_name, details, price, price_unit, status, is_group_deal, created_at from building_quotes where building_id = b.id) q), '[]'::json)
  );
end $$;

create or replace function public.building_vote(p_building uuid, p_device uuid) returns json
language plpgsql security definer set search_path = public as $$
declare b apartments; n int;
begin
  select * into b from apartments where id = p_building and kind = 'building' and deleted_at is null for update;
  if b.id is null then raise exception 'not found'; end if;
  if b.connection_status <> 'pending_interest' then return json_build_object('interest_count', b.interest_count, 'counted', false); end if;
  insert into building_interest(building_id, device_id) values (b.id, p_device) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then update apartments set interest_count = interest_count + 1 where id = b.id returning interest_count into b.interest_count; end if;
  return json_build_object('interest_count', b.interest_count, 'counted', n > 0);
end $$;

revoke execute on function public.building_public(text, uuid) from public, anon, authenticated;
revoke execute on function public.building_vote(uuid, uuid) from public, anon, authenticated;
grant execute on function public.building_public(text, uuid) to service_role;
grant execute on function public.building_vote(uuid, uuid) to service_role;

-- 5. cleaning a building: same flow, its own 4 photos (entrance, stairs, floors, bins)
create or replace function public.finish_cleaning(p_task uuid, p_photos jsonb, p_checklist jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare t tasks; k text; v_kind text;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null or t.primary_cleaner is distinct from auth.uid() then raise exception 'המשימה לא משובצת אליך'; end if;
  if t.status not in ('in_progress','needs_fix') then raise exception 'הניקיון לא התחיל'; end if;
  select kind into v_kind from apartments where id = t.apartment_id;
  foreach k in array case when v_kind = 'building' then array['entrance','stairs','floors','bins'] else array['bed','bath','kitchen','living'] end loop
    if coalesce(p_photos->>k, '') = '' then raise exception 'חסרות תמונות סיום (4 חובה)'; end if;
  end loop;
  if exists (select 1 from jsonb_each(p_checklist) where value <> 'true'::jsonb) or p_checklist = '{}'::jsonb then
    raise exception 'יש לסמן את כל סעיפי הצ׳ק-ליסט'; end if;
  update tasks set status = 'submitted', finished_at = now(), photos = p_photos, checklist = p_checklist
  where id = p_task;
end $$;

-- the site address that NFC stickers point to (set once, before burning real stickers)
alter table public.settings add column if not exists public_base_url text;
