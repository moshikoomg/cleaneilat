-- CleanEilat — smart money: referral caps + monthly payouts

alter table public.settings
  add column if not exists referral_cap_ratio numeric not null default 0,       -- optional: referrals ≤ X × own cleaning pay (0 = no cap)
  add column if not exists referral_monthly_cap numeric not null default 0,     -- optional: hard cap per person per month (0 = no cap)
  add column if not exists referral_months int not null default 0;              -- 0 = no time limit; N = only a friend's first N months

create table if not exists public.payouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  period date not null,                       -- first day of the month
  task_amount numeric not null default 0,
  referral_earned numeric not null default 0,
  referral_paid numeric not null default 0,
  referral_forfeited numeric not null default 0,
  total numeric not null default 0,
  status text not null default 'pending' check (status in ('pending','paid')),
  reference text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, period)
);
alter table public.payouts enable row level security;
drop policy if exists payouts_read on public.payouts;
create policy payouts_read on public.payouts for select to authenticated using (user_id = auth.uid() or fn_is_admin());
drop policy if exists payouts_admin on public.payouts;
create policy payouts_admin on public.payouts for all to authenticated using (fn_is_admin()) with check (fn_is_admin());

alter table public.wallet_entries add column if not exists payout_id uuid references public.payouts on delete set null;

-- the money rules, in one place
create or replace function public.fn_payout_calc(p_user uuid, p_month date)
returns table (task_amount numeric, referral_earned numeric, cap numeric, referral_paid numeric, referral_forfeited numeric, total numeric, unlocked boolean)
language sql stable security definer set search_path = public as $$
  with s as (select * from settings where id = 1),
  m as (select date_trunc('month', p_month)::date as a, (date_trunc('month', p_month) + interval '1 month')::date as b),
  e as (
    select coalesce(sum(amount) filter (where kind in ('task','bonus','adjust')), 0) as t,
           coalesce(sum(amount) filter (where kind = 'referral'), 0) as r
    from wallet_entries w, m
    where w.user_id = p_user and w.created_at >= m.a and w.created_at < m.b
  ),
  c as (select e.t, e.r,
          least(case when s.referral_cap_ratio > 0 then e.t * s.referral_cap_ratio else 1e12 end,
                case when s.referral_monthly_cap > 0 then s.referral_monthly_cap else 1e12 end) as cap
        from e, s)
  select c.t, c.r, case when c.cap >= 1e12 then null else c.cap end,
         case when c.t > 0 then least(c.r, c.cap) else 0 end,
         c.r - case when c.t > 0 then least(c.r, c.cap) else 0 end,
         c.t + case when c.t > 0 then least(c.r, c.cap) else 0 end,
         c.t > 0
  from c;
$$;

create or replace function public.payout_preview(p_month date)
returns table (user_id uuid, full_name text, phone text, is_verified boolean, task_amount numeric, referral_earned numeric,
               cap numeric, referral_paid numeric, referral_forfeited numeric, total numeric, unlocked boolean,
               payout_id uuid, payout_status text, reference text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  return query
  select p.id, p.full_name, p.phone, p.is_verified,
         coalesce(po.task_amount, c.task_amount), coalesce(po.referral_earned, c.referral_earned),
         case when po.id is null then c.cap else null end,
         coalesce(po.referral_paid, c.referral_paid), coalesce(po.referral_forfeited, c.referral_forfeited),
         coalesce(po.total, c.total), c.unlocked, po.id, po.status, po.reference
  from profiles p
  cross join lateral fn_payout_calc(p.id, p_month) c
  left join payouts po on po.user_id = p.id and po.period = date_trunc('month', p_month)::date
  where c.task_amount > 0 or c.referral_earned > 0 or po.id is not null
  order by coalesce(po.total, c.total) desc;
end $$;

create or replace function public.create_payouts(p_month date)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; n int := 0; m date := date_trunc('month', p_month)::date;
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  if m >= date_trunc('month', fn_today())::date then raise exception 'אפשר להפיק תשלומים רק לחודש שהסתיים'; end if;
  for r in select * from payout_preview(m) where payout_id is null and total > 0 loop
    insert into payouts (user_id, period, task_amount, referral_earned, referral_paid, referral_forfeited, total)
    values (r.user_id, m, r.task_amount, r.referral_earned, r.referral_paid, r.referral_forfeited, r.total)
    returning id into v_id;
    update wallet_entries set payout_id = v_id
      where user_id = r.user_id and payout_id is null and created_at >= m and created_at < (m + interval '1 month');
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.mark_payout_paid(p_payout uuid, p_reference text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not fn_is_admin() then raise exception 'admin only'; end if;
  update payouts set status = 'paid', reference = nullif(p_reference, ''), paid_at = now()
  where id = p_payout and status = 'pending';
  if not found then raise exception 'התשלום כבר סומן או לא קיים'; end if;
end $$;

-- commissions only during a friend's first N months
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
  if c.referred_by is not null and (s.referral_months = 0 or c.created_at > now() - make_interval(months => s.referral_months)) then
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

-- wallet now reports the capped, payable commission
create or replace function public.my_wallet(p_month date default null)
returns json language sql stable security definer set search_path = public as $$
  with c as (select * from fn_payout_calc(auth.uid(), coalesce(p_month, fn_today()))),
       s as (select * from settings where id = 1)
  select json_build_object(
    'task_total', c.task_amount,
    'referral_total', c.referral_earned,
    'referral_payable', c.referral_paid,
    'referral_forfeited', c.referral_forfeited,
    'referral_cap', c.cap,
    'cap_ratio', s.referral_cap_ratio,
    'monthly_cap', s.referral_monthly_cap,
    'referral_months', s.referral_months,
    'total', c.total,
    'referral_count', (select count(*) from wallet_entries w where w.user_id = auth.uid() and w.kind = 'referral'
        and w.created_at >= date_trunc('month', coalesce(p_month, fn_today())) and w.created_at < date_trunc('month', coalesce(p_month, fn_today())) + interval '1 month'),
    'own_cleanings', (select count(*) from tasks t where t.primary_cleaner = auth.uid() and t.status = 'approved'
        and t.approved_at >= date_trunc('month', coalesce(p_month, fn_today())) and t.approved_at < date_trunc('month', coalesce(p_month, fn_today())) + interval '1 month'),
    'unlocked', c.unlocked,
    'pending_review', coalesce((select sum(coalesce(t.cleaner_pay, case when p.is_verified then a.rate_max else a.rate_base end))
        from tasks t join apartments a on a.id = t.apartment_id join profiles p on p.id = auth.uid()
        where t.primary_cleaner = auth.uid() and t.status = 'submitted'), 0)
  ) from c, s;
$$;

revoke execute on function public.fn_payout_calc(uuid, date) from public, anon, authenticated;
revoke execute on function public.payout_preview(date), public.create_payouts(date), public.mark_payout_paid(uuid, text) from public, anon;
grant execute on function public.payout_preview(date), public.create_payouts(date), public.mark_payout_paid(uuid, text), public.my_wallet(date) to authenticated;
