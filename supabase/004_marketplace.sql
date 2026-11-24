-- CleanEilat — marketplace model (like Turno)
-- Hosts and independent cleaners contract directly. CleanEilat provides the software only:
-- cleaners set their own prices, hosts approve the work and pay the cleaner directly,
-- and CleanEilat earns a monthly subscription per apartment.

alter table public.settings
  add column if not exists monthly_fee numeric not null default 49,
  add column if not exists trial_days int not null default 30;

alter table public.profiles
  add column if not exists bio text,
  add column if not exists area text,
  add column if not exists prices jsonb not null default '{}',      -- {"studio":120,"1":150,"2":180,"3":220}
  add column if not exists payment_info text,                       -- shown only to connected hosts
  add column if not exists rating numeric,
  add column if not exists rating_count int not null default 0,
  add column if not exists sub_status text not null default 'trial' check (sub_status in ('trial','active','past_due','cancelled')),
  add column if not exists trial_ends date;

alter table public.apartments
  add column if not exists size text not null default '1' check (size in ('studio','1','2','3')),
  add column if not exists cleaner_id uuid references public.profiles on delete set null,
  add column if not exists notes text;

create table if not exists public.connections (
  host_id uuid not null references public.profiles on delete cascade,
  cleaner_id uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  primary key (host_id, cleaner_id)
);

alter table public.tasks
  add column if not exists host_id uuid references public.profiles,
  add column if not exists price numeric,
  add column if not exists offer_status text not null default 'none' check (offer_status in ('none','offered','accepted','declined')),
  add column if not exists paid_at timestamptz,
  add column if not exists rating int check (rating between 1 and 5),
  add column if not exists review text;
create index if not exists tasks_host on public.tasks (host_id, task_date);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles on delete cascade,
  cleaner_id uuid not null references public.profiles on delete cascade,
  sender_id uuid not null references public.profiles on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists messages_pair on public.messages (host_id, cleaner_id, created_at);

-- ───────── helpers ─────────
create or replace function public.fn_price(p_cleaner uuid, p_size text) returns numeric
language sql stable security definer set search_path = public as $$
  select nullif(prices->>p_size, '')::numeric from profiles where id = p_cleaner;
$$;
create or replace function public.fn_connected(p_host uuid, p_cleaner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from connections where host_id = p_host and cleaner_id = p_cleaner and status = 'accepted');
$$;
create or replace function public.fn_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and status = 'approved';
$$;

-- every new cleaning: owner + the apartment's regular cleaner (as an offer) + that cleaner's price
create or replace function public.tg_task_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare a apartments;
begin
  select * into a from apartments where id = new.apartment_id;
  new.host_id := a.host_id;
  if new.primary_cleaner is null and a.cleaner_id is not null and fn_connected(a.host_id, a.cleaner_id) then
    new.primary_cleaner := a.cleaner_id;
    new.offer_status := 'offered';
  end if;
  if new.primary_cleaner is not null and new.price is null then
    new.price := fn_price(new.primary_cleaner, a.size);
  end if;
  return new;
end $$;
drop trigger if exists task_defaults on public.tasks;
create trigger task_defaults before insert on public.tasks for each row execute function public.tg_task_defaults();

-- ───────── RLS ─────────
drop policy if exists apartments_read on public.apartments;
create policy apartments_read on public.apartments for select to authenticated
  using (fn_is_admin() or host_id = auth.uid() or cleaner_id = auth.uid() or fn_cleans_apartment(id));
drop policy if exists apartments_host_ins on public.apartments;
create policy apartments_host_ins on public.apartments for insert to authenticated
  with check (host_id = auth.uid() and fn_role() = 'host');
drop policy if exists apartments_host_upd on public.apartments;
create policy apartments_host_upd on public.apartments for update to authenticated
  using (host_id = auth.uid()) with check (host_id = auth.uid());
drop policy if exists apartments_host_del on public.apartments;
create policy apartments_host_del on public.apartments for delete to authenticated using (host_id = auth.uid());

drop policy if exists secrets_host on public.apartment_secrets;
create policy secrets_host on public.apartment_secrets for all to authenticated
  using (fn_owns_apartment(apartment_id)) with check (fn_owns_apartment(apartment_id));

drop policy if exists tasks_host_ins on public.tasks;
create policy tasks_host_ins on public.tasks for insert to authenticated
  with check (fn_owns_apartment(apartment_id) and fn_role() = 'host');

alter table public.connections enable row level security;
drop policy if exists conn_read on public.connections;
create policy conn_read on public.connections for select to authenticated
  using (auth.uid() in (host_id, cleaner_id) or fn_is_admin());

alter table public.messages enable row level security;
drop policy if exists msg_read on public.messages;
create policy msg_read on public.messages for select to authenticated
  using (auth.uid() in (host_id, cleaner_id) or fn_is_admin());
drop policy if exists msg_ins on public.messages;
create policy msg_ins on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and auth.uid() in (host_id, cleaner_id) and fn_connected(host_id, cleaner_id));

-- ───────── onboarding & profile ─────────
create or replace function public.submit_onboarding_v2(
  p_role text, p_full_name text, p_phone text, p_answers jsonb, p_area text, p_bio text,
  p_prices jsonb, p_payment_info text, p_business_type text, p_business_number text,
  p_id_doc_path text, p_business_doc_path text)
returns text language plpgsql security definer set search_path = public as $$
declare v_status text; s settings;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_role not in ('host','cleaner') then raise exception 'bad role'; end if;
  if coalesce(trim(p_full_name),'') = '' or coalesce(trim(p_phone),'') = '' then raise exception 'נא למלא שם וטלפון'; end if;
  select * into s from settings where id = 1;
  if p_role = 'cleaner' then
    if coalesce(p_id_doc_path,'') = '' then raise exception 'נדרש צילום תעודת זהות'; end if;
    if coalesce(p_business_doc_path,'') = '' then raise exception 'נדרש אישור עוסק'; end if;
  end if;
  update profiles set
    desired_role = p_role, full_name = trim(p_full_name), phone = trim(p_phone), onboarding = coalesce(p_answers,'{}'),
    area = p_area, bio = p_bio, prices = coalesce(p_prices, '{}'), payment_info = p_payment_info,
    business_type = p_business_type, business_number = p_business_number,
    id_doc_path = p_id_doc_path, business_doc_path = p_business_doc_path, rejection_reason = null,
    role = case when role = 'admin' then role when p_role = 'host' then 'host' else role end,
    status = case when role = 'admin' or p_role = 'host' then 'approved' else 'submitted' end,
    trial_ends = case when p_role = 'host' then coalesce(trial_ends, fn_today() + s.trial_days) else trial_ends end
  where id = auth.uid()
  returning status into v_status;
  return v_status;
end $$;

create or replace function public.update_my_profile(p_full_name text, p_phone text, p_area text, p_bio text, p_prices jsonb, p_payment_info text)
returns void language sql security definer set search_path = public as $$
  update profiles set full_name = coalesce(nullif(trim(p_full_name),''), full_name), phone = coalesce(nullif(trim(p_phone),''), phone),
    area = p_area, bio = p_bio, prices = coalesce(p_prices, prices), payment_info = p_payment_info
  where id = auth.uid();
$$;

-- ───────── directory & connections ─────────
create or replace function public.list_cleaners()
returns table (id uuid, full_name text, avatar_url text, area text, bio text, prices jsonb, rating numeric, rating_count int, connection text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.avatar_url, p.area, p.bio, p.prices, p.rating, p.rating_count,
         (select c.status from connections c where c.host_id = auth.uid() and c.cleaner_id = p.id)
  from profiles p
  where p.role = 'cleaner' and p.status = 'approved' and fn_role() in ('host','admin')
  order by p.rating desc nulls last, p.rating_count desc, p.full_name;
$$;

create or replace function public.request_connection(p_cleaner uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if fn_role() <> 'host' then raise exception 'רק בעלי דירות יכולים לשלוח בקשה'; end if;
  if not exists (select 1 from profiles where id = p_cleaner and role = 'cleaner' and status = 'approved') then
    raise exception 'המנקה לא זמין/ה'; end if;
  insert into connections (host_id, cleaner_id, status) values (auth.uid(), p_cleaner, 'pending')
  on conflict (host_id, cleaner_id) do update set status = case when connections.status = 'accepted' then 'accepted' else 'pending' end, created_at = now();
end $$;

create or replace function public.respond_connection(p_host uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update connections set status = case when p_accept then 'accepted' else 'declined' end
  where host_id = p_host and cleaner_id = auth.uid() and status = 'pending';
  if not found then raise exception 'אין בקשה פתוחה'; end if;
end $$;

create or replace function public.my_contacts()
returns table (id uuid, full_name text, avatar_url text, phone text, payment_info text, prices jsonb, rating numeric, status text, side text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.avatar_url,
         case when c.status = 'accepted' then p.phone end,
         case when c.status = 'accepted' then p.payment_info end,
         p.prices, p.rating, c.status, 'cleaner'
  from connections c join profiles p on p.id = c.cleaner_id where c.host_id = auth.uid()
  union all
  select p.id, p.full_name, p.avatar_url,
         case when c.status = 'accepted' then p.phone end, null, null, null, c.status, 'host'
  from connections c join profiles p on p.id = c.host_id where c.cleaner_id = auth.uid();
$$;

create or replace function public.set_apartment_cleaner(p_apt uuid, p_cleaner uuid) returns int
language plpgsql security definer set search_path = public as $$
declare a apartments; n int := 0;
begin
  select * into a from apartments where id = p_apt;
  if a.id is null or a.host_id <> auth.uid() then raise exception 'הדירה לא שייכת לך'; end if;
  if p_cleaner is not null and not fn_connected(auth.uid(), p_cleaner) then raise exception 'המנקה עוד לא אישר/ה את החיבור'; end if;
  update apartments set cleaner_id = p_cleaner where id = p_apt;
  if p_cleaner is not null then
    update tasks set primary_cleaner = p_cleaner, offer_status = 'offered', price = fn_price(p_cleaner, a.size)
    where apartment_id = p_apt and primary_cleaner is null and status = 'pending' and task_date >= fn_today();
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- ───────── cleanings ─────────
create or replace function public.create_task(p_apt uuid, p_date date, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not fn_owns_apartment(p_apt) then raise exception 'הדירה לא שייכת לך'; end if;
  if p_date < fn_today() then raise exception 'תאריך עבר'; end if;
  insert into tasks (apartment_id, task_date, status, source, request_note, requested_by)
  values (p_apt, p_date, 'pending', 'host', nullif(p_note,''), auth.uid()) returning id into v;
  return v;
end $$;

create or replace function public.cancel_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update tasks set status = 'cancelled'
  where id = p_task and host_id = auth.uid() and status in ('pending','requested','arrived');
  if not found then raise exception 'אי אפשר לבטל ניקיון שכבר התחיל'; end if;
end $$;

create or replace function public.respond_task(p_task uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    update tasks set offer_status = 'accepted' where id = p_task and primary_cleaner = auth.uid() and offer_status = 'offered';
  else
    update tasks set primary_cleaner = null, price = null, offer_status = 'declined'
    where id = p_task and primary_cleaner = auth.uid() and offer_status = 'offered';
  end if;
  if not found then raise exception 'ההצעה כבר לא בתוקף'; end if;
end $$;

drop function if exists public.open_pool();
create function public.open_pool()
returns table (id uuid, task_date date, window_start time, window_end time, apartment text, complex text, address text, size text, pay numeric)
language sql stable security definer set search_path = public as $$
  select t.id, t.task_date, t.window_start, t.window_end, a.name, c.name, a.address, a.size, fn_price(auth.uid(), a.size)
  from tasks t join apartments a on a.id = t.apartment_id left join complexes c on c.id = a.complex_id
  where fn_role() = 'cleaner' and t.primary_cleaner is null and t.status = 'pending' and t.task_date >= fn_today()
  order by t.task_date, t.window_start;
$$;

create or replace function public.claim_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks; a apartments; v_price numeric;
begin
  if fn_role() <> 'cleaner' then raise exception 'רק מנקים מאושרים'; end if;
  select * into t from tasks where id = p_task for update;
  if t.id is null or t.primary_cleaner is not null or t.status <> 'pending' then raise exception 'הניקיון כבר נתפס'; end if;
  select * into a from apartments where id = t.apartment_id;
  v_price := fn_price(auth.uid(), a.size);
  if v_price is null then raise exception 'קבעו קודם מחיר לגודל הדירה הזה בפרופיל'; end if;
  update tasks set primary_cleaner = auth.uid(), price = v_price, offer_status = 'accepted' where id = p_task;
  insert into connections (host_id, cleaner_id, status) values (a.host_id, auth.uid(), 'accepted')
  on conflict (host_id, cleaner_id) do update set status = 'accepted';
end $$;

create or replace function public.reveal_entry_code(p_task uuid)
returns json language plpgsql security definer set search_path = public as $$
declare t tasks; s apartment_secrets;
begin
  select * into t from tasks where id = p_task;
  if t.id is null or t.primary_cleaner is distinct from auth.uid() then raise exception 'הניקיון לא משובץ אליך'; end if;
  if t.offer_status <> 'accepted' then raise exception 'קודם צריך לאשר את הניקיון'; end if;
  if t.task_date > fn_today() then raise exception 'הקוד ייחשף ביום הניקיון'; end if;
  if t.status in ('approved','cancelled') then raise exception 'הניקיון סגור'; end if;
  update tasks set arrived_at = coalesce(arrived_at, now()),
    status = case when status in ('pending','requested') then 'arrived' else status end where id = p_task;
  select * into s from apartment_secrets where apartment_id = t.apartment_id;
  return json_build_object('code', s.entry_code, 'notes', s.lockbox_notes);
end $$;

create or replace function public.host_approve(p_task uuid, p_rating int, p_review text) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if t.id is null or t.host_id <> auth.uid() then raise exception 'הניקיון לא שלך'; end if;
  if t.status <> 'submitted' then raise exception 'אפשר לאשר רק ניקיון שהסתיים'; end if;
  if p_rating is not null and (p_rating < 1 or p_rating > 5) then raise exception 'דירוג 1–5'; end if;
  update tasks set status = 'approved', approved_at = now(), approved_by = auth.uid(), rating = p_rating,
    review = nullif(trim(coalesce(p_review,'')),''), admin_note = null where id = p_task;
  update profiles set
    rating = (select round(avg(rating)::numeric, 2) from tasks where primary_cleaner = t.primary_cleaner and rating is not null),
    rating_count = (select count(*) from tasks where primary_cleaner = t.primary_cleaner and rating is not null)
  where id = t.primary_cleaner;
end $$;

create or replace function public.host_needs_fix(p_task uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update tasks set status = 'needs_fix', admin_note = p_note where id = p_task and host_id = auth.uid() and status = 'submitted';
  if not found then raise exception 'אפשר לבקש תיקון רק לניקיון שהסתיים'; end if;
end $$;

create or replace function public.mark_paid(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update tasks set paid_at = now() where id = p_task and host_id = auth.uid() and status = 'approved' and paid_at is null;
  if not found then raise exception 'כבר סומן או שהניקיון עוד לא אושר'; end if;
end $$;

create or replace function public.cleaner_earnings(p_month date default null) returns json
language sql stable security definer set search_path = public as $$
  with m as (select date_trunc('month', coalesce(p_month, fn_today()))::date a)
  select json_build_object(
    'count', count(*),
    'total', coalesce(sum(price), 0),
    'paid', coalesce(sum(price) filter (where paid_at is not null), 0),
    'unpaid', coalesce(sum(price) filter (where paid_at is null), 0))
  from tasks t, m where t.primary_cleaner = auth.uid() and t.status = 'approved'
    and t.approved_at >= m.a and t.approved_at < m.a + interval '1 month';
$$;

-- ───────── platform admin ─────────
create or replace function public.admin_set_sub(p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  update profiles set sub_status = p_status where id = p_user and role = 'host';
end $$;

create or replace function public.admin_overview() returns json
language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  select json_build_object(
    'hosts', (select count(*) from profiles where role = 'host'),
    'cleaners', (select count(*) from profiles where role = 'cleaner' and status = 'approved'),
    'pending_cleaners', (select count(*) from profiles where status = 'submitted'),
    'apartments', (select count(*) from apartments a join profiles p on p.id = a.host_id where a.active),
    'paying_apartments', (select count(*) from apartments a join profiles p on p.id = a.host_id where a.active and p.sub_status = 'active'),
    'mrr', (select count(*) from apartments a join profiles p on p.id = a.host_id where a.active and p.sub_status = 'active') * (select monthly_fee from settings where id = 1),
    'cleanings_month', (select count(*) from tasks where status = 'approved' and approved_at >= date_trunc('month', now())),
    'synced_apartments', (select count(*) from apartments where ical_url is not null)
  ) into r;
  return r;
end $$;

-- execute rights: signed-in users only
revoke execute on function public.fn_price(uuid,text), public.fn_connected(uuid,uuid), public.fn_role() from public, anon;
revoke execute on function public.submit_onboarding_v2(text,text,text,jsonb,text,text,jsonb,text,text,text,text,text),
  public.update_my_profile(text,text,text,text,jsonb,text), public.list_cleaners(), public.request_connection(uuid),
  public.respond_connection(uuid,boolean), public.my_contacts(), public.set_apartment_cleaner(uuid,uuid),
  public.create_task(uuid,date,text), public.cancel_task(uuid), public.respond_task(uuid,boolean), public.open_pool(),
  public.claim_task(uuid), public.host_approve(uuid,int,text), public.host_needs_fix(uuid,text), public.mark_paid(uuid),
  public.cleaner_earnings(date), public.admin_set_sub(uuid,text), public.admin_overview() from public, anon;
grant execute on function public.fn_price(uuid,text), public.fn_connected(uuid,uuid), public.fn_role(),
  public.submit_onboarding_v2(text,text,text,jsonb,text,text,jsonb,text,text,text,text,text),
  public.update_my_profile(text,text,text,text,jsonb,text), public.list_cleaners(), public.request_connection(uuid),
  public.respond_connection(uuid,boolean), public.my_contacts(), public.set_apartment_cleaner(uuid,uuid),
  public.create_task(uuid,date,text), public.cancel_task(uuid), public.respond_task(uuid,boolean), public.open_pool(),
  public.claim_task(uuid), public.host_approve(uuid,int,text), public.host_needs_fix(uuid,text), public.mark_paid(uuid),
  public.cleaner_earnings(date), public.admin_set_sub(uuid,text), public.admin_overview() to authenticated;
revoke execute on function public.tg_task_defaults() from public, anon, authenticated;

alter publication supabase_realtime add table public.messages;
