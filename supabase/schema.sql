-- CleanEilat — schema, RLS, RPCs, storage
-- Run once on a fresh Supabase project.

create extension if not exists pgcrypto;

-- ───────────── settings ─────────────
create table public.settings (
  id int primary key default 1 check (id = 1),
  referral_fee numeric not null default 10,       -- ₪ per apartment cleaned by a referred friend
  urgent_surcharge numeric not null default 80,   -- ₪ added to host price on urgent requests
  pool_delay_hours int not null default 3,        -- how long new tasks are exclusive to verified cleaners
  deposit_amount numeric not null default 1500,
  updated_at timestamptz default now()
);
insert into public.settings default values;

-- ───────────── profiles ─────────────
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  phone text,
  role text not null default 'pending' check (role in ('pending','cleaner','host','admin')),
  desired_role text check (desired_role in ('cleaner','host')),
  status text not null default 'new' check (status in ('new','submitted','approved','rejected')),
  onboarding jsonb not null default '{}',
  business_type text check (business_type in ('osek_zair','osek_murshe','company')),
  business_number text,
  id_doc_path text,
  business_doc_path text,
  deposit_status text not null default 'none' check (deposit_status in ('none','requested','paid','refunded')),
  is_verified boolean not null default false,
  referral_code text unique default substr(md5(gen_random_uuid()::text), 1, 7),
  referred_by uuid references public.profiles(id),
  rejection_reason text,
  created_at timestamptz not null default now()
);

-- ───────────── places ─────────────
create table public.complexes (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_premium boolean not null default false,
  sort int not null default 0
);

create table public.apartments (
  id uuid primary key default gen_random_uuid(),
  complex_id uuid references public.complexes on delete set null,
  host_id uuid references public.profiles on delete set null,
  name text not null,
  address text,
  host_price numeric not null default 260,
  rate_base numeric not null default 120,
  rate_max numeric not null default 150,
  is_premium boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.apartment_secrets (
  apartment_id uuid primary key references public.apartments on delete cascade,
  entry_code text,
  lockbox_notes text
);

-- ───────────── tasks ─────────────
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  apartment_id uuid not null references public.apartments on delete cascade,
  task_date date not null default ((now() at time zone 'Asia/Jerusalem')::date),
  window_start time not null default '11:00',
  window_end time not null default '15:00',
  primary_cleaner uuid references public.profiles,
  backup_cleaner uuid references public.profiles,
  status text not null default 'pending'
    check (status in ('requested','pending','arrived','in_progress','submitted','approved','needs_fix','cancelled')),
  is_urgent boolean not null default false,
  is_extra boolean not null default false,
  requested_by uuid references public.profiles,
  request_note text,
  published_at timestamptz not null default now(),
  arrived_at timestamptz,
  started_at timestamptz,
  start_lat double precision,
  start_lng double precision,
  start_accuracy double precision,
  finished_at timestamptz,
  before_photos text[] not null default '{}',
  damage_notes text,
  photos jsonb not null default '{}',
  checklist jsonb not null default '{}',
  admin_note text,
  approved_at timestamptz,
  approved_by uuid references public.profiles,
  host_price numeric,
  cleaner_pay numeric,
  referral_fee numeric not null default 0,
  created_at timestamptz not null default now()
);
create index on public.tasks (task_date);
create index on public.tasks (primary_cleaner);
create index on public.tasks (backup_cleaner);
create index on public.tasks (apartment_id);

create table public.wallet_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  task_id uuid references public.tasks on delete set null,
  kind text not null check (kind in ('task','referral','bonus','adjust')),
  amount numeric not null,
  source_cleaner uuid references public.profiles,
  created_at timestamptz not null default now(),
  unique (task_id, kind, user_id)
);
create index on public.wallet_entries (user_id, created_at);

-- ───────────── helpers (security definer → no RLS recursion) ─────────────
create or replace function public.fn_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.fn_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Jerusalem')::date $$;

create or replace function public.fn_owns_apartment(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from apartments where id = a and host_id = auth.uid());
$$;

create or replace function public.fn_cleans_apartment(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tasks where apartment_id = a
                 and auth.uid() in (primary_cleaner, backup_cleaner));
$$;

create or replace function public.fn_task_role(t uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when fn_is_admin() then 'admin'
    when exists (select 1 from tasks where id = t and auth.uid() in (primary_cleaner, backup_cleaner)) then 'cleaner'
    when exists (select 1 from tasks tk join apartments ap on ap.id = tk.apartment_id
                 where tk.id = t and ap.host_id = auth.uid()) then 'host'
    else null end;
$$;

-- ───────────── new user trigger ─────────────
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, full_name, avatar_url)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
          new.raw_user_meta_data->>'avatar_url');
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ───────────── RLS ─────────────
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.complexes enable row level security;
alter table public.apartments enable row level security;
alter table public.apartment_secrets enable row level security;
alter table public.tasks enable row level security;
alter table public.wallet_entries enable row level security;

create policy settings_read on public.settings for select to authenticated using (true);
create policy settings_admin on public.settings for update to authenticated using (fn_is_admin()) with check (fn_is_admin());

create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or fn_is_admin());
create policy profiles_admin on public.profiles for update to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

create policy complexes_read on public.complexes for select to authenticated using (true);
create policy complexes_admin on public.complexes for all to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

create policy apartments_read on public.apartments for select to authenticated
  using (fn_is_admin() or host_id = auth.uid() or fn_cleans_apartment(id));
create policy apartments_admin on public.apartments for all to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

create policy secrets_admin on public.apartment_secrets for all to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

create policy tasks_read on public.tasks for select to authenticated
  using (fn_is_admin() or auth.uid() in (primary_cleaner, backup_cleaner) or fn_owns_apartment(apartment_id));
create policy tasks_admin on public.tasks for all to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

create policy wallet_read on public.wallet_entries for select to authenticated
  using (user_id = auth.uid() or fn_is_admin());
create policy wallet_admin on public.wallet_entries for all to authenticated
  using (fn_is_admin()) with check (fn_is_admin());

-- ───────────── RPC: onboarding & users ─────────────
create or replace function public.submit_onboarding(
  p_desired_role text, p_full_name text, p_phone text, p_answers jsonb,
  p_business_type text, p_business_number text,
  p_id_doc_path text, p_business_doc_path text, p_ref text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ref uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_desired_role not in ('cleaner','host') then raise exception 'bad role'; end if;
  if coalesce(p_id_doc_path,'') = '' then raise exception 'נדרש צילום תעודת זהות'; end if;
  if p_desired_role = 'cleaner' and coalesce(p_business_doc_path,'') = '' then
    raise exception 'נדרש אישור עוסק'; end if;
  if p_ref is not null and p_ref <> '' then
    select id into v_ref from profiles where referral_code = p_ref and id <> auth.uid();
  end if;
  update profiles set
    desired_role = p_desired_role, full_name = p_full_name, phone = p_phone,
    onboarding = coalesce(p_answers, '{}'), business_type = p_business_type,
    business_number = p_business_number, id_doc_path = p_id_doc_path,
    business_doc_path = p_business_doc_path,
    referred_by = coalesce(referred_by, v_ref),
    status = case when role = 'admin' then 'approved' else 'submitted' end,
    rejection_reason = null
  where id = auth.uid();
end $$;

create or replace function public.admin_review_user(p_user uuid, p_approve boolean, p_role text default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  update profiles set
    status = case when p_approve then 'approved' else 'rejected' end,
    role = case when p_approve then coalesce(p_role, desired_role, role) else role end,
    rejection_reason = case when p_approve then null else p_reason end
  where id = p_user;
end $$;

create or replace function public.admin_set_verified(p_user uuid, p_verified boolean, p_deposit_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  update profiles set is_verified = p_verified, deposit_status = p_deposit_status where id = p_user;
end $$;

create or replace function public.request_deposit_track() returns void
language sql security definer set search_path = public as $$
  update profiles set deposit_status = 'requested'
  where id = auth.uid() and role = 'cleaner' and deposit_status = 'none';
$$;

create or replace function public.my_referrals()
returns table (first_name text, joined date, approved_this_month bigint, active boolean)
language sql stable security definer set search_path = public as $$
  select split_part(coalesce(p.full_name,'חבר/ה'), ' ', 1), p.created_at::date,
         (select count(*) from tasks t where t.primary_cleaner = p.id and t.status = 'approved'
            and date_trunc('month', t.approved_at) = date_trunc('month', now())),
         p.status = 'approved'
  from profiles p where p.referred_by = auth.uid() order by p.created_at desc;
$$;

create or replace function public.my_wallet(p_month date default null)
returns json language sql stable security definer set search_path = public as $$
  with m as (select date_trunc('month', coalesce(p_month, fn_today())::timestamptz) as s),
  own as (
    select count(*) c from tasks t, m where t.primary_cleaner = auth.uid() and t.status = 'approved'
      and t.approved_at >= m.s and t.approved_at < m.s + interval '1 month')
  select json_build_object(
    'task_total', coalesce((select sum(amount) from wallet_entries w, m where w.user_id = auth.uid()
        and w.kind in ('task','bonus','adjust') and w.created_at >= m.s and w.created_at < m.s + interval '1 month'),0),
    'referral_total', coalesce((select sum(amount) from wallet_entries w, m where w.user_id = auth.uid()
        and w.kind = 'referral' and w.created_at >= m.s and w.created_at < m.s + interval '1 month'),0),
    'referral_count', (select count(*) from wallet_entries w, m where w.user_id = auth.uid()
        and w.kind = 'referral' and w.created_at >= m.s and w.created_at < m.s + interval '1 month'),
    'own_cleanings', (select c from own),
    'unlocked', (select c from own) >= 1,
    'pending_review', coalesce((select sum(coalesce(t.cleaner_pay, case when p.is_verified then a.rate_max else a.rate_base end))
        from tasks t join apartments a on a.id = t.apartment_id join profiles p on p.id = auth.uid()
        where t.primary_cleaner = auth.uid() and t.status = 'submitted'),0)
  );
$$;

-- ───────────── RPC: cleaner field flow ─────────────
create or replace function public.reveal_entry_code(p_task uuid)
returns json language plpgsql security definer set search_path = public as $$
declare t tasks; s apartment_secrets;
begin
  select * into t from tasks where id = p_task;
  if t.id is null or not (auth.uid() is not distinct from t.primary_cleaner or auth.uid() is not distinct from t.backup_cleaner) then
    raise exception 'המשימה לא משובצת אליך'; end if;
  if t.task_date > fn_today() then raise exception 'הקוד ייחשף ביום הניקיון'; end if;
  if t.status in ('approved','cancelled') then raise exception 'המשימה סגורה'; end if;
  update tasks set arrived_at = coalesce(arrived_at, now()),
    status = case when status in ('pending','requested') then 'arrived' else status end
  where id = p_task;
  select * into s from apartment_secrets where apartment_id = t.apartment_id;
  return json_build_object('code', s.entry_code, 'notes', s.lockbox_notes);
end $$;

create or replace function public.start_cleaning(p_task uuid, p_lat double precision, p_lng double precision,
  p_accuracy double precision, p_before_photos text[], p_damage_notes text)
returns void language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null or not (auth.uid() is not distinct from t.primary_cleaner or auth.uid() is not distinct from t.backup_cleaner) then
    raise exception 'המשימה לא משובצת אליך'; end if;
  if t.status <> 'arrived' then raise exception 'יש ללחוץ קודם על "הגעתי לדירה"'; end if;
  if coalesce(array_length(p_before_photos, 1), 0) < 1 then
    raise exception 'צריך לפחות תמונת מצב אחת לפני שמתחילים'; end if;
  update tasks set status = 'in_progress', started_at = now(),
    start_lat = p_lat, start_lng = p_lng, start_accuracy = p_accuracy,
    before_photos = p_before_photos, damage_notes = nullif(p_damage_notes, ''),
    -- backup cleaner stepping in becomes the paid cleaner
    primary_cleaner = auth.uid(),
    backup_cleaner = case when auth.uid() = t.backup_cleaner then t.primary_cleaner else t.backup_cleaner end
  where id = p_task;
end $$;

create or replace function public.finish_cleaning(p_task uuid, p_photos jsonb, p_checklist jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare t tasks; k text;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null or t.primary_cleaner is distinct from auth.uid() then raise exception 'המשימה לא משובצת אליך'; end if;
  if t.status not in ('in_progress','needs_fix') then raise exception 'הניקיון לא התחיל'; end if;
  foreach k in array array['bed','bath','kitchen','living'] loop
    if coalesce(p_photos->>k, '') = '' then raise exception 'חסרות תמונות סיום (4 חובה)'; end if;
  end loop;
  if exists (select 1 from jsonb_each(p_checklist) where value <> 'true'::jsonb) or p_checklist = '{}'::jsonb then
    raise exception 'יש לסמן את כל סעיפי הצ׳ק-ליסט'; end if;
  update tasks set status = 'submitted', finished_at = now(), photos = p_photos, checklist = p_checklist
  where id = p_task;
end $$;

create or replace function public.open_pool()
returns table (id uuid, task_date date, window_start time, window_end time, is_urgent boolean,
               apartment text, complex text, address text, is_premium boolean, pay numeric, exclusive_until timestamptz)
language sql stable security definer set search_path = public as $$
  with me as (select * from profiles where id = auth.uid() and role = 'cleaner' and status = 'approved'),
       s as (select * from settings where id = 1)
  select t.id, t.task_date, t.window_start, t.window_end, t.is_urgent,
         a.name, c.name, a.address, (a.is_premium or coalesce(c.is_premium,false)),
         case when me.is_verified then a.rate_max else a.rate_base end,
         t.published_at + make_interval(hours => s.pool_delay_hours)
  from tasks t join apartments a on a.id = t.apartment_id
  left join complexes c on c.id = a.complex_id
  cross join me cross join s
  where t.primary_cleaner is null and t.status in ('pending','requested') and t.task_date >= fn_today()
    and (me.is_verified or (not (a.is_premium or coalesce(c.is_premium,false))
         and t.published_at + make_interval(hours => s.pool_delay_hours) < now()))
  order by t.is_urgent desc, t.task_date, (a.is_premium or coalesce(c.is_premium,false)) desc;
$$;

create or replace function public.claim_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from open_pool() where id = p_task) then
    raise exception 'המשימה כבר נתפסה או לא זמינה עבורך'; end if;
  update tasks set primary_cleaner = auth.uid(), status = 'pending' where id = p_task and primary_cleaner is null;
end $$;

-- ───────────── RPC: admin QA & money ─────────────
create or replace function public.admin_approve(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks; a apartments; c profiles; s settings; v_pay numeric; v_host numeric; v_ref numeric := 0;
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  select * into t from tasks where id = p_task for update;
  if t.status <> 'submitted' then raise exception 'אפשר לאשר רק ניקיון שהוגש'; end if;
  select * into a from apartments where id = t.apartment_id;
  select * into c from profiles where id = t.primary_cleaner;
  select * into s from settings where id = 1;
  v_pay := coalesce(t.cleaner_pay, case when c.is_verified then a.rate_max else a.rate_base end);
  v_host := coalesce(t.host_price, a.host_price + case when t.is_urgent then s.urgent_surcharge else 0 end);
  if c.referred_by is not null then v_ref := s.referral_fee; end if;
  update tasks set status = 'approved', approved_at = now(), approved_by = auth.uid(),
    cleaner_pay = v_pay, host_price = v_host, referral_fee = v_ref, admin_note = null
  where id = p_task;
  insert into wallet_entries (user_id, task_id, kind, amount) values (c.id, t.id, 'task', v_pay)
    on conflict do nothing;
  if v_ref > 0 then
    insert into wallet_entries (user_id, task_id, kind, amount, source_cleaner)
      values (c.referred_by, t.id, 'referral', v_ref, c.id) on conflict do nothing;
  end if;
end $$;

create or replace function public.admin_needs_fix(p_task uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  update tasks set status = 'needs_fix', admin_note = p_note where id = p_task and status = 'submitted';
end $$;

-- ───────────── RPC: host ─────────────
create or replace function public.request_cleaning(p_apartment uuid, p_date date, p_urgent boolean, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; a apartments; s settings;
begin
  if not fn_owns_apartment(p_apartment) then raise exception 'הדירה לא שייכת לך'; end if;
  if p_date < fn_today() then raise exception 'תאריך עבר'; end if;
  select * into a from apartments where id = p_apartment;
  select * into s from settings where id = 1;
  insert into tasks (apartment_id, task_date, status, is_urgent, is_extra, requested_by, request_note, host_price)
  values (p_apartment, p_date, 'requested', p_urgent, true, auth.uid(), p_note,
          a.host_price + case when p_urgent then s.urgent_surcharge else 0 end)
  returning id into v_id;
  return v_id;
end $$;

-- lock down RPC execution to signed-in users
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- ───────────── storage ─────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('task-photos', 'task-photos', false, 5242880, array['image/jpeg','image/png','image/webp']),
  ('kyc', 'kyc', false, 8388608, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create or replace function public.fn_safe_uuid(t text) returns uuid
language plpgsql immutable as $$ begin return t::uuid; exception when others then return null; end $$;
grant execute on function public.fn_safe_uuid(text) to authenticated;

create policy kyc_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
create policy kyc_read on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and ((storage.foldername(name))[1] = auth.uid()::text or public.fn_is_admin()));

create policy photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'task-photos'
    and public.fn_task_role(public.fn_safe_uuid((storage.foldername(name))[1])) in ('cleaner','admin'));
create policy photos_read on storage.objects for select to authenticated
  using (bucket_id = 'task-photos'
    and public.fn_task_role(public.fn_safe_uuid((storage.foldername(name))[1])) is not null);

-- ───────────── realtime ─────────────
alter publication supabase_realtime add table public.tasks;

-- ───────────── seed ─────────────
insert into public.complexes (name, is_premium, sort) values
  ('הטרמינל', true, 1), ('שחמון', false, 2), ('צופית', false, 3), ('מרכז העיר', false, 4)
on conflict do nothing;

alter function public.fn_today() set search_path = public;
alter function public.fn_safe_uuid(text) set search_path = public;

-- Make yourself admin after first sign-in (replace the email):
-- update public.profiles set role = 'admin', status = 'approved' where email = 'you@example.com';
