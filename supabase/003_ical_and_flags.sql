-- CleanEilat — Airbnb calendar sync + feature flags

-- feature flags (launch phase: both off)
alter table public.settings
  add column if not exists feature_deposit boolean not null default false,
  add column if not exists feature_referral boolean not null default false;
drop policy if exists settings_public on public.settings;
create policy settings_public on public.settings for select to anon using (true);

-- calendar sync columns
alter table public.apartments
  add column if not exists ical_url text,
  add column if not exists ical_synced_at timestamptz,
  add column if not exists ical_error text;
alter table public.tasks
  add column if not exists source text not null default 'manual' check (source in ('manual','ical','host')),
  add column if not exists booking_uid text;
create unique index if not exists tasks_booking_uid on public.tasks (apartment_id, booking_uid) where booking_uid is not null;

-- secrets only the server can read (RLS on, no policies)
create table if not exists public.app_secrets (name text primary key, value text not null);
alter table public.app_secrets enable row level security;
insert into public.app_secrets (name, value) values ('cron_key', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (name) do nothing;

-- referral fees only when the program is on
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
  v_pay := coalesce(t.cleaner_pay, case when s.feature_deposit and c.is_verified then a.rate_max else a.rate_base end);
  v_host := coalesce(t.host_price, a.host_price + case when t.is_urgent then s.urgent_surcharge else 0 end);
  if s.feature_referral and c.referred_by is not null
     and (s.referral_months = 0 or c.created_at > now() - make_interval(months => s.referral_months)) then
    v_ref := s.referral_fee;
  end if;
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

-- open board: verified priority only when the deposit track is on
create or replace function public.open_pool()
returns table (id uuid, task_date date, window_start time, window_end time, is_urgent boolean,
               apartment text, complex text, address text, is_premium boolean, pay numeric, exclusive_until timestamptz)
language sql stable security definer set search_path = public as $$
  with me as (select * from profiles where id = auth.uid() and role = 'cleaner' and status = 'approved'),
       s as (select * from settings where id = 1)
  select t.id, t.task_date, t.window_start, t.window_end, t.is_urgent,
         a.name, c.name, a.address, (a.is_premium or coalesce(c.is_premium,false)),
         case when s.feature_deposit and me.is_verified then a.rate_max else a.rate_base end,
         t.published_at + make_interval(hours => s.pool_delay_hours)
  from tasks t join apartments a on a.id = t.apartment_id
  left join complexes c on c.id = a.complex_id
  cross join me cross join s
  where t.primary_cleaner is null and t.status in ('pending','requested') and t.task_date >= fn_today()
    and (not s.feature_deposit or me.is_verified or (not (a.is_premium or coalesce(c.is_premium,false))
         and t.published_at + make_interval(hours => s.pool_delay_hours) < now()))
  order by t.is_urgent desc, t.task_date, (a.is_premium or coalesce(c.is_premium,false)) desc;
$$;

-- hourly sync (pg_cron + pg_net call the ical-sync Edge Function)
create extension if not exists pg_net;
create extension if not exists pg_cron;
select cron.unschedule('ical-sync') where exists (select 1 from cron.job where jobname = 'ical-sync');
select cron.schedule('ical-sync', '7 * * * *', $cron$
  select net.http_post(
    url := 'https://qmcvdjvnpaaclgestgtp.supabase.co/functions/v1/ical-sync',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-key', (select value from public.app_secrets where name = 'cron_key')),
    body := '{}'::jsonb);
$cron$);
