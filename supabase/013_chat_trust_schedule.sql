-- 013: in-app chat (contact details masked), trust-based auto approval, recurring schedule (fixed hours or flexible day).

-- ═════════ chat ═════════
alter table public.messages add column if not exists read_at timestamptz;

-- Phone numbers and e-mails are hidden so deals and payments stay documented in the app.
create or replace function public.fn_mask_contacts(t text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(t, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[מייל הוסתר]', 'g'),
             '(\+?\s?972|0)([\s\-\.]?\d){8,9}', '[מספר הוסתר]', 'g'),
           '(wa\.me|whatsapp\.com|t\.me)/\S*', '[קישור הוסתר]', 'gi') $$;

create or replace function public.tg_messages_mask() returns trigger
language plpgsql set search_path = public as $$
begin
  new.body := fn_mask_contacts(new.body);
  new.read_at := null;
  return new;
end $$;
create or replace trigger messages_mask before insert on public.messages for each row execute function public.tg_messages_mask();

-- chat is open once a committee asked a cleaner (pending) or they are connected
create or replace function public.fn_chat_allowed(p_host uuid, p_cleaner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from connections where host_id = p_host and cleaner_id = p_cleaner and status in ('pending','accepted')) $$;

alter policy msg_ins on public.messages
  with check (sender_id = auth.uid() and auth.uid() in (host_id, cleaner_id) and fn_chat_allowed(host_id, cleaner_id));

create or replace function public.chat_read(p_other uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update messages set read_at = now()
  where read_at is null and sender_id = p_other and auth.uid() in (host_id, cleaner_id) and p_other in (host_id, cleaner_id);
  get diagnostics n = row_count; return n;
end $$;

-- contacts: phone stays hidden from the other side (talk in the chat); payment details still show once connected
create or replace function public.my_contacts()
returns table (id uuid, full_name text, avatar_url text, phone text, payment_info text, prices jsonb, rating numeric, status text, side text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.avatar_url, null::text,
         case when c.status = 'accepted' then p.payment_info end,
         p.prices, p.rating, c.status, 'cleaner'
  from connections c join profiles p on p.id = c.cleaner_id where c.host_id = auth.uid()
  union all
  select p.id, p.full_name, p.avatar_url, null::text, null, null, null, c.status, 'host'
  from connections c join profiles p on p.id = c.host_id where c.cleaner_id = auth.uid();
$$;

-- ═════════ trust-based auto approval ═════════
alter table public.connections add column if not exists auto_approve boolean not null default false;
alter table public.connections add column if not exists auto_paused_at timestamptz;
alter table public.tasks add column if not exists approved_via text;   -- committee | timeout | trust | admin

-- consecutive good cleanings (latest first): approved, and no resident cleaning report within 48h after it
create or replace function public.fn_trust_streak(p_building uuid, p_cleaner uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id, status, finished_at from tasks
           where apartment_id = p_building and primary_cleaner = p_cleaner and status in ('submitted','approved','needs_fix') and finished_at is not null
           order by finished_at desc limit 20 loop
    exit when r.status = 'needs_fix';
    exit when exists (select 1 from building_issues i where i.building_id = p_building and i.category = 'cleaning'
                      and i.created_at >= r.finished_at and i.created_at < r.finished_at + interval '48 hours');
    if r.status = 'approved' then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function public.set_auto_approve(p_cleaner uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  select id into b from apartments where kind = 'building' and host_id = auth.uid() and cleaner_id = p_cleaner and deleted_at is null limit 1;
  if b is null then raise exception 'המנקה לא משויך/ת לבניין שלך'; end if;
  if p_on and fn_trust_streak(b, p_cleaner) < 3 then raise exception 'אישור אוטומטי נפתח אחרי 3 ניקיונות תקינים ברצף'; end if;
  update connections set auto_approve = p_on, auto_paused_at = null where host_id = auth.uid() and cleaner_id = p_cleaner and status = 'accepted';
  if not found then raise exception 'אין חיבור פעיל עם המנקה'; end if;
  return p_on;
end $$;

-- when a trusted cleaner checked in and finished with all photos, the cleaning is approved on the spot
create or replace function public.tg_trust_approve() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' and new.arrived_at is not null
     and exists (select 1 from apartments a join connections c on c.host_id = a.host_id and c.cleaner_id = new.primary_cleaner
                 where a.id = new.apartment_id and a.kind = 'building' and c.status = 'accepted' and c.auto_approve) then
    new.status := 'approved'; new.approved_at := now(); new.approved_via := 'trust';
  end if;
  return new;
end $$;
create or replace trigger trust_approve before update on public.tasks for each row execute function public.tg_trust_approve();

-- a resident cleaning report pauses auto approval and tells the committee
create or replace function public.tg_issue_pause_trust() returns trigger
language plpgsql security definer set search_path = public as $$
declare a apartments;
begin
  if new.category <> 'cleaning' then return new; end if;
  select * into a from apartments where id = new.building_id;
  update connections set auto_approve = false, auto_paused_at = now()
  where host_id = a.host_id and cleaner_id = a.cleaner_id and auto_approve;
  if found then
    insert into notices (audience, user_id, kind, title, body)
    values ('user', a.host_id, 'alert', 'האישור האוטומטי הושהה',
            'דייר דיווח על בעיה בניקיון. מעכשיו תאשרו את הניקיונות בעצמכם. אחרי 3 ניקיונות תקינים ברצף אפשר להפעיל שוב.');
  end if;
  return new;
end $$;
create or replace trigger issue_pause_trust after insert on public.building_issues for each row execute function public.tg_issue_pause_trust();

create or replace function public.auto_approve_building_cleanings() returns integer
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update tasks t set status = 'approved', approved_at = now(), approved_via = 'timeout'
  from apartments a
  where a.id = t.apartment_id and a.kind = 'building' and t.status = 'submitted'
    and t.finished_at < now() - interval '48 hours'
    and not exists (select 1 from building_issues i where i.building_id = a.id and i.category = 'cleaning' and i.created_at >= t.finished_at);
  get diagnostics n = row_count;
  return n;
end $$;

-- ═════════ recurring schedule ═════════
-- schedule = {days:[0..6], flex:bool, from:'HH:MM', to:'HH:MM', price:num, note:text}; flex = any time during the day
alter table public.apartments add column if not exists schedule jsonb;
alter table public.apartments add column if not exists schedule_status text not null default 'none';
alter table public.tasks add column if not exists from_schedule boolean not null default false;

-- schedule fields change only through the RPCs below; a new cleaner must accept the schedule again
create or replace function public.tg_schedule_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('ce.sched', true), '') <> '1' and auth.uid() is not null and not fn_is_admin() then
    new.schedule := old.schedule; new.schedule_status := old.schedule_status;
  end if;
  if new.cleaner_id is distinct from old.cleaner_id then
    new.schedule_status := case when new.schedule is null then 'none' when new.cleaner_id is null then 'none' else 'offered' end;
    update tasks set status = 'cancelled'
    where apartment_id = new.id and from_schedule and status = 'pending' and task_date >= fn_today() and primary_cleaner is distinct from new.cleaner_id;
  end if;
  return new;
end $$;
create or replace trigger schedule_guard before update on public.apartments for each row execute function public.tg_schedule_guard();

create or replace function public.gen_schedule_tasks(p_building uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare a apartments; d date; n int := 0; s jsonb;
begin
  for a in select * from apartments where kind = 'building' and deleted_at is null and schedule_status = 'accepted'
           and cleaner_id is not null and schedule is not null and (p_building is null or id = p_building) loop
    s := a.schedule;
    for i in 0..13 loop
      d := fn_today() + i;
      continue when not (s->'days') @> to_jsonb(extract(dow from d)::int);
      continue when exists (select 1 from tasks where apartment_id = a.id and task_date = d and status <> 'cancelled');
      insert into tasks (apartment_id, task_date, window_start, window_end, price, request_note, source, primary_cleaner, offer_status, from_schedule)
      values (a.id, d,
              case when (s->>'flex')::boolean then '00:00'::time else (s->>'from')::time end,
              case when (s->>'flex')::boolean then '23:59'::time else (s->>'to')::time end,
              nullif(s->>'price', '')::numeric, nullif(s->>'note', ''), 'host', a.cleaner_id, 'accepted', true);
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

create or replace function public.set_schedule(p_building uuid, p_days int[], p_flex boolean, p_from time, p_to time, p_price numeric, p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare a apartments; s jsonb;
begin
  select * into a from apartments where id = p_building and kind = 'building' and host_id = auth.uid() and deleted_at is null;
  if a.id is null then raise exception 'הבניין לא שייך לך'; end if;
  perform set_config('ce.sched', '1', true);
  -- future, not-started schedule cleanings are rebuilt from the new schedule
  update tasks set status = 'cancelled' where apartment_id = a.id and from_schedule and status = 'pending' and task_date >= fn_today();
  if coalesce(array_length(p_days, 1), 0) = 0 then
    update apartments set schedule = null, schedule_status = 'none' where id = a.id;
    return 'none';
  end if;
  if exists (select 1 from unnest(p_days) x where x < 0 or x > 6) then raise exception 'ימים לא תקינים'; end if;
  if not p_flex and (p_from is null or p_to is null or p_to <= p_from) then raise exception 'שעת הסיום צריכה להיות אחרי שעת ההתחלה'; end if;
  s := jsonb_build_object('days', to_jsonb(p_days), 'flex', p_flex, 'from', to_char(p_from, 'HH24:MI'), 'to', to_char(p_to, 'HH24:MI'),
                          'price', p_price, 'note', left(coalesce(p_note, ''), 300));
  update apartments set schedule = s, schedule_status = case when cleaner_id is null then 'none' else 'offered' end where id = a.id;
  return case when a.cleaner_id is null then 'none' else 'offered' end;
end $$;

create or replace function public.respond_schedule(p_building uuid, p_accept boolean) returns int
language plpgsql security definer set search_path = public as $$
declare a apartments;
begin
  select * into a from apartments where id = p_building and kind = 'building' and cleaner_id = auth.uid() and schedule_status = 'offered';
  if a.id is null then raise exception 'אין הצעה פתוחה לבניין הזה'; end if;
  perform set_config('ce.sched', '1', true);
  update apartments set schedule_status = case when p_accept then 'accepted' else 'declined' end where id = a.id;
  if p_accept then return gen_schedule_tasks(a.id); end if;
  return 0;
end $$;

-- cleaners see the schedule offer for buildings they are assigned to
create or replace function public.my_schedule_offers() returns table (id uuid, address text, schedule jsonb, schedule_status text, committee text)
language sql stable security definer set search_path = public as $$
  select a.id, a.address, a.schedule, a.schedule_status, p.full_name
  from apartments a left join profiles p on p.id = a.host_id
  where a.kind = 'building' and a.deleted_at is null and a.cleaner_id = auth.uid() and a.schedule is not null $$;

-- committee's view of trust for its building cleaner
create or replace function public.my_trust() returns table (cleaner_id uuid, streak int, auto_approve boolean, auto_paused_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.cleaner_id, fn_trust_streak(a.id, a.cleaner_id), coalesce(c.auto_approve, false), c.auto_paused_at
  from apartments a left join connections c on c.host_id = a.host_id and c.cleaner_id = a.cleaner_id
  where a.kind = 'building' and a.deleted_at is null and a.host_id = auth.uid() and a.cleaner_id is not null $$;

-- cleaner sees which committees trust them
create or replace function public.my_trusted_by() returns table (host_id uuid, auto_approve boolean)
language sql stable security definer set search_path = public as $$
  select host_id, auto_approve from connections where cleaner_id = auth.uid() and status = 'accepted' $$;

revoke execute on function public.gen_schedule_tasks(uuid) from public, anon, authenticated;
revoke execute on function public.fn_trust_streak(uuid, uuid) from public, anon;
grant execute on function public.chat_read(uuid), public.set_auto_approve(uuid, boolean), public.set_schedule(uuid, int[], boolean, time, time, numeric, text),
  public.respond_schedule(uuid, boolean), public.my_schedule_offers(), public.my_trust(), public.my_trusted_by() to authenticated;
revoke execute on function public.chat_read(uuid), public.set_auto_approve(uuid, boolean), public.set_schedule(uuid, int[], boolean, time, time, numeric, text),
  public.respond_schedule(uuid, boolean), public.my_schedule_offers(), public.my_trust(), public.my_trusted_by() from anon;

select cron.schedule('schedule-tasks', '23 2 * * *', 'select public.gen_schedule_tasks()');

-- cleaner's schedules incl. the committee id (replaces my_schedule_offers in the app)
create or replace function public.my_schedules() returns table (id uuid, address text, schedule jsonb, schedule_status text, committee text, host_id uuid)
language sql stable security definer set search_path = public as $$
  select a.id, a.address, a.schedule, a.schedule_status, p.full_name, a.host_id
  from apartments a left join profiles p on p.id = a.host_id
  where a.kind = 'building' and a.deleted_at is null and a.cleaner_id = auth.uid() and a.schedule is not null $$;
revoke execute on function public.my_schedules() from public, anon;
grant execute on function public.my_schedules() to authenticated;
