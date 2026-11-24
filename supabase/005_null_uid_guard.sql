-- Guard: a caller without an identity must never match an unassigned task
create or replace function public.reveal_entry_code(p_task uuid)
returns json language plpgsql security definer set search_path = public as $$
declare t tasks; s apartment_secrets;
begin
  select * into t from tasks where id = p_task;
  if auth.uid() is null or t.id is null or not coalesce(auth.uid() = t.primary_cleaner or auth.uid() = t.backup_cleaner, false) then
    raise exception 'הניקיון לא משובץ אליך'; end if;
  if t.offer_status = 'offered' and t.primary_cleaner = auth.uid() then raise exception 'קודם צריך לאשר את הניקיון'; end if;
  if t.task_date > fn_today() then raise exception 'הקוד ייחשף ביום הניקיון'; end if;
  if t.status in ('approved','cancelled') then raise exception 'הניקיון סגור'; end if;
  update tasks set arrived_at = coalesce(arrived_at, now()),
    status = case when status in ('pending','requested') then 'arrived' else status end where id = p_task;
  select * into s from apartment_secrets where apartment_id = t.apartment_id;
  return json_build_object('code', s.entry_code, 'notes', s.lockbox_notes);
end $$;

create or replace function public.start_cleaning(p_task uuid, p_lat double precision, p_lng double precision,
  p_accuracy double precision, p_before_photos text[], p_damage_notes text)
returns void language plpgsql security definer set search_path = public as $$
declare t tasks;
begin
  select * into t from tasks where id = p_task for update;
  if auth.uid() is null or t.id is null or not coalesce(auth.uid() = t.primary_cleaner or auth.uid() = t.backup_cleaner, false) then
    raise exception 'המשימה לא משובצת אליך'; end if;
  if t.status <> 'arrived' then raise exception 'יש ללחוץ קודם על "הגעתי לדירה"'; end if;
  if coalesce(array_length(p_before_photos, 1), 0) < 1 then
    raise exception 'צריך לפחות תמונת מצב אחת לפני שמתחילים'; end if;
  update tasks set status = 'in_progress', started_at = now(),
    start_lat = p_lat, start_lng = p_lng, start_accuracy = p_accuracy,
    before_photos = p_before_photos, damage_notes = nullif(p_damage_notes, ''),
    primary_cleaner = auth.uid(),
    backup_cleaner = case when auth.uid() = t.backup_cleaner then t.primary_cleaner else t.backup_cleaner end
  where id = p_task;
end $$;
