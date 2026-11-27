-- 012: super admin (mosheally@gmail.com), audit log, notices to committees / cleaners / residents.

-- ── super admin flag ──
alter table public.profiles add column if not exists is_super boolean not null default false;
alter table public.profiles add column if not exists blocked_at timestamptz;

create or replace function public.fn_is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_super from profiles where id = auth.uid()), false) $$;

-- Only the database itself (migrations / service role) can grant super; only a super admin can grant or remove 'admin'.
create or replace function public.tg_protect_super() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- migrations and the service role (edge functions) carry no user id
  if auth.uid() is null then return new; end if;
  if new.is_super is distinct from old.is_super then raise exception 'not allowed'; end if;
  if (new.role = 'admin') is distinct from (old.role = 'admin') and not fn_is_super() then raise exception 'only super admin'; end if;
  if old.is_super and auth.uid() <> old.id then
    if new.role is distinct from old.role or new.status is distinct from old.status or new.blocked_at is distinct from old.blocked_at then
      raise exception 'not allowed'; end if;
  end if;
  return new;
end $$;
create or replace trigger tg_protect_super before update on public.profiles for each row execute function public.tg_protect_super();

update public.profiles set is_super = true, role = 'admin', status = 'approved'
  where id = (select id from auth.users where lower(email) = 'mosheally@gmail.com');

-- ── audit log (written by the admin-tools edge function only) ──
create table if not exists public.admin_audit (
  id bigint generated always as identity primary key,
  admin_id uuid not null references public.profiles(id),
  action text not null,
  target_user uuid,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
alter table public.admin_audit enable row level security;
create policy admin_audit_read on public.admin_audit for select to authenticated using (fn_is_super());

-- ── notices ──
create table if not exists public.notices (
  id uuid primary key default gen_random_uuid(),
  created_by uuid references public.profiles(id) on delete set null,
  audience text not null check (audience in ('members','committee','cleaner','residents','user')),
  building_id uuid references public.apartments(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  kind text not null default 'notice' check (kind in ('notice','tip','alert')),
  title text not null check (length(title) between 1 and 120),
  body text not null default '' check (length(body) <= 1500),
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  check (audience <> 'user' or user_id is not null)
);
create index if not exists notices_active_idx on public.notices (active, created_at desc);
create table if not exists public.notice_reads (
  notice_id uuid not null references public.notices(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notice_id, user_id)
);
alter table public.notices enable row level security;
alter table public.notice_reads enable row level security;

create or replace function public.fn_notice_visible(n public.notices) returns boolean
language sql stable security definer set search_path = public as $$
  select n.active and (n.expires_at is null or n.expires_at > now()) and exists (
    select 1 from profiles p where p.id = auth.uid() and p.status = 'approved' and (
         (n.audience = 'members' and p.role in ('host','cleaner'))
      or (n.audience = 'committee' and p.role = 'host' and (n.building_id is null
            or exists (select 1 from apartments a where a.id = n.building_id and a.host_id = p.id)))
      or (n.audience = 'cleaner' and p.role = 'cleaner' and (n.building_id is null
            or exists (select 1 from apartments a where a.id = n.building_id and a.cleaner_id = p.id)))
      or (n.audience = 'user' and n.user_id = p.id))) $$;

create policy notices_read on public.notices for select to authenticated using (fn_is_admin() or fn_notice_visible(notices));
create policy notices_admin on public.notices for all to authenticated using (fn_is_admin()) with check (fn_is_admin());
create policy notice_reads_own on public.notice_reads for select to authenticated using (user_id = auth.uid() or fn_is_admin());
create policy notice_reads_insert on public.notice_reads for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from notices n where n.id = notice_id and fn_notice_visible(n)));

-- residents see notices on the building page
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
,
    'notices', coalesce((select json_agg(n order by n.created_at desc) from (
        select id, kind, title, body, created_at from notices
        where audience = 'residents' and active and (expires_at is null or expires_at > now())
          and (building_id is null or building_id = b.id)
        order by created_at desc limit 3) n), '[]'::json)
  );
end $$;
revoke all on function public.building_public(text, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.building_public(text, uuid, text, uuid) to service_role;
