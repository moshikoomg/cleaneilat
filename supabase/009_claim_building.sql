-- Committee sign-up: find buildings that were already opened (e.g. by stickers / admin) and claim one,
-- instead of creating a duplicate. Votes and NFC tags stay attached because the row is the same.

create or replace function public.fn_norm_addr(t text) returns text
language sql immutable as $$
  select regexp_replace(regexp_replace(lower(coalesce(t, '')), '(^|\s)(רחוב|רח''|רח)(\s|$)', ' ', 'g'), '[^א-תa-z0-9]', '', 'g');
$$;

-- unclaimed buildings in a city (no committee yet), exact address match first
create or replace function public.find_buildings(p_city text, p_address text)
returns table(id uuid, address text, city text, units_count int, interest_count int, status text, tags int, exact boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.address, a.city, a.units_count, a.interest_count, a.connection_status,
         (select count(*)::int from nfc_tags n where n.building_id = a.id),
         fn_norm_addr(a.address) = fn_norm_addr(p_address) and fn_norm_addr(p_address) <> ''
  from apartments a
  where auth.uid() is not null and a.kind = 'building' and a.deleted_at is null and a.host_id is null
    and fn_norm_addr(a.city) = fn_norm_addr(p_city) and fn_norm_addr(p_city) <> ''
  order by 8 desc, a.interest_count desc, a.address
  limit 50;
$$;

-- link the signed-in committee account to an unclaimed building and activate it
create or replace function public.claim_building(p_building uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare b apartments;
begin
  if auth.uid() is null or fn_role() <> 'host' then raise exception 'צריך חשבון ועד בית כדי לחבר בניין'; end if;
  select * into b from apartments where id = p_building and kind = 'building' and deleted_at is null for update;
  if b.id is null then raise exception 'הבניין לא נמצא'; end if;
  if b.host_id is not null and b.host_id <> auth.uid() then raise exception 'הבניין כבר מחובר לוועד אחר. כתבו לנו ונבדוק'; end if;
  update apartments set host_id = auth.uid(), connection_status = 'active' where id = b.id;
  return b.id;
end $$;

revoke execute on function public.find_buildings(text, text) from public, anon;
revoke execute on function public.claim_building(uuid) from public, anon;
grant execute on function public.find_buildings(text, text) to authenticated;
grant execute on function public.claim_building(uuid) to authenticated;
