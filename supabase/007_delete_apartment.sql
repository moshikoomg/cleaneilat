-- "Remove apartment" = soft delete (archive). The row is never deleted, so past cleanings,
-- photos, ratings and cleaner earnings stay intact.
alter table public.apartments add column if not exists deleted_at timestamptz;

create or replace function public.delete_apartment(p_apt uuid) returns text
language plpgsql security definer set search_path = public as $$
declare a apartments;
begin
  select * into a from apartments where id = p_apt for update;
  if a.id is null or auth.uid() is null or not (a.host_id = auth.uid() or fn_is_admin()) then
    raise exception 'הדירה לא שייכת לך'; end if;
  if a.deleted_at is not null then return 'archived'; end if;
  if exists (select 1 from tasks where apartment_id = p_apt and status in ('arrived','in_progress','submitted','needs_fix')) then
    raise exception 'יש ניקיון שמתבצע עכשיו בדירה. אפשר להסיר אותה אחרי שהוא יסתיים ויאושר'; end if;
  -- future cleanings that were not done yet are cancelled; history is untouched
  update tasks set status = 'cancelled' where apartment_id = p_apt and status in ('pending','requested');
  -- hidden from the host, out of the board and out of automatic calendar sync
  update apartments set deleted_at = now(), active = false where id = p_apt;
  return 'archived';
end $$;
revoke execute on function public.delete_apartment(uuid) from public, anon;
grant execute on function public.delete_apartment(uuid) to authenticated;

-- archived apartments can't be edited back by the host, and hosts can't hard-delete rows at all
drop policy if exists apartments_host_upd on public.apartments;
create policy apartments_host_upd on public.apartments for update to authenticated
  using (host_id = auth.uid() and deleted_at is null) with check (host_id = auth.uid() and deleted_at is null);
drop policy if exists apartments_host_del on public.apartments;
