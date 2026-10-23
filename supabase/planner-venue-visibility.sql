-- Let planners read requests only for their assigned venue.
-- The existing admin, requester, and bus-company policies remain in place.

create table if not exists public.wedrive_planner_venues (
  user_id uuid primary key references auth.users(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.wedrive_planner_venues enable row level security;
revoke all on table public.wedrive_planner_venues from anon, authenticated;
grant select on table public.wedrive_planner_venues to authenticated;

drop policy if exists "wedrive planners read own venue membership" on public.wedrive_planner_venues;
create policy "wedrive planners read own venue membership"
on public.wedrive_planner_venues
for select to authenticated
using (user_id=(select auth.uid()) or public.wedrive_has_role(array['運行管理スタッフ']::text[]));

create or replace function public.wedrive_admin_set_user_role(
  p_email text,
  p_name text,
  p_role text,
  p_organization_id uuid default null
) returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  if not public.wedrive_has_role(array['運行管理スタッフ']::text[]) then
    raise exception '管理者のみ役割を設定できます' using errcode = '42501';
  end if;
  if p_role not in ('運行管理スタッフ','式場プランナー','バス会社','運転者')
     or nullif(trim(p_email),'') is null
     or nullif(trim(p_name),'') is null then
    raise exception '入力内容を確認してください' using errcode = '22023';
  end if;
  select id into v_id from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  if v_id is null then
    raise exception '先にこのメールアドレスでWEDRIVEに登録してください' using errcode = 'P0002';
  end if;
  if p_role='式場プランナー' and not exists (select 1 from public.venues v where v.id=p_organization_id) then
    raise exception 'プランナーの所属式場を選択してください' using errcode = '22023';
  end if;
  if p_role in ('バス会社','運転者') and not exists (select 1 from public.organizations o where o.id=p_organization_id and o.type='bus_company') then
    raise exception '所属するバス会社を選択してください' using errcode = '22023';
  end if;
  update public.wedrive_user_roles set role=p_role where user_id=v_id;
  if not found then
    insert into public.wedrive_user_roles(user_id,role) values(v_id,p_role);
  end if;
  update public.profiles
     set organization_id=case when p_role='式場プランナー' then null else p_organization_id end,
         name=trim(p_name), role=p_role
   where id=v_id;
  if not found then
    insert into public.profiles(id,organization_id,name,role)
    values(v_id,case when p_role='式場プランナー' then null else p_organization_id end,trim(p_name),p_role);
  end if;
  if p_role='式場プランナー' then
    insert into public.wedrive_planner_venues(user_id,venue_id)
    values(v_id,p_organization_id)
    on conflict(user_id) do update set venue_id=excluded.venue_id;
  else
    delete from public.wedrive_planner_venues where user_id=v_id;
  end if;
end
$function$;

-- Existing planner account is the sole configured planner and is assigned to the only venue.
do $migration$
declare
  v_venue uuid;
  v_planner_count integer;
begin
  select id into v_venue from public.venues where name='THE CENTRAL PARK KOKURA';
  if v_venue is null then
    raise exception 'THE CENTRAL PARK KOKURA is not configured as a venue';
  end if;
  select count(*) into v_planner_count from public.profiles where role='式場プランナー';
  if v_planner_count <> 1 then
    raise exception 'Expected exactly one existing planner profile to assign; found %', v_planner_count;
  end if;
  insert into public.wedrive_planner_venues(user_id,venue_id)
  select id,v_venue from public.profiles where role='式場プランナー'
  on conflict(user_id) do update set venue_id=excluded.venue_id;
end
$migration$;

create policy "wedrive planners read requests from their venue"
on public.transport_requests
for select to authenticated
using (
  public.wedrive_has_role(array['式場プランナー']::text[])
  and exists (
    select 1 from public.wedrive_planner_venues pv
    where pv.user_id=(select auth.uid())
      and pv.venue_id=transport_requests.venue_id
  )
);
