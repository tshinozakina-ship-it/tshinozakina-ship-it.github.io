-- Allows the two units of one shuttle request to have different operating times.
-- Existing checks for role, company, date, route, pending status, unit numbers, and distinct drivers remain.
CREATE OR REPLACE FUNCTION public.wedrive_accept_shuttle_batch(p_request_ids uuid[], p_contact_name text, p_driver_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
 v_company uuid;
 v_contact text:=pg_catalog.btrim(coalesce(p_contact_name,''));
 v_req public.transport_requests%rowtype;
 v_base public.transport_requests%rowtype;
 v_n int:=0;
 v_expected int;
 v_slotnum int;
 v_slottotal int;
 v_slot text[];
 v_match text[];
 v_key text;
 v_basekey text;
 v_slots int[]:=array[]::int[];
 v_driver uuid;
 v_at timestamptz:=pg_catalog.now();
begin
 if not public.wedrive_has_role(array['バス会社']::text[]) then raise exception 'バス会社アカウントでログインしてください' using errcode='42501'; end if;
 if v_contact='' or pg_catalog.char_length(v_contact)>100 then raise exception '受注担当者名を1〜100文字で入力してください' using errcode='22023'; end if;
 if p_request_ids is null or pg_catalog.cardinality(p_request_ids)<>2 or (select count(*) from unnest(p_request_ids) x(id))<>(select count(distinct id) from unnest(p_request_ids) x(id)) then raise exception '2台分の依頼を選択してください' using errcode='22023'; end if;
 if p_driver_ids is null or pg_catalog.cardinality(p_driver_ids)<>2 or exists(select 1 from unnest(p_driver_ids) x(id) where id is null) or (select count(distinct id) from unnest(p_driver_ids) x(id))<>2 then raise exception '2台それぞれに異なる乗務員を選択してください' using errcode='22023'; end if;
 select organization_id into v_company from public.profiles where id=(select auth.uid());
 if v_company is null then raise exception 'アカウントに会社が設定されていません' using errcode='42501'; end if;
 perform 1 from public.drivers where id=any(p_driver_ids) order by id for update;
 if (select count(*) from public.drivers where id=any(p_driver_ids))<>2 then raise exception '選択した乗務員を確認できません' using errcode='22023'; end if;
 for v_req in select r.* from public.transport_requests r where r.id=any(p_request_ids) order by r.id for update loop
  v_n:=v_n+1;
  if v_req.status<>'pending' then raise exception '2台分とも未受注であることを確認してください' using errcode='P0002'; end if;
  if v_req.bus_company_id is distinct from v_company then raise exception 'この依頼は貴社宛てではありません' using errcode='42501'; end if;
  if coalesce(v_req.notes,'') not like '%【シャトルバス】%' then raise exception 'シャトルバスの依頼ではありません' using errcode='22023'; end if;
  v_match:=pg_catalog.regexp_match(coalesce(v_req.notes,''),'発注台数：([0-9]+)台');
  v_slot:=pg_catalog.regexp_match(coalesce(v_req.notes,''),'車両番号：([0-9]+)/([0-9]+)台');
  if v_match is null or v_slot is null then raise exception '台数情報を確認できません' using errcode='22023'; end if;
  v_expected:=v_match[1]::int; v_slotnum:=v_slot[1]::int; v_slottotal:=v_slot[2]::int;
  if v_expected<>2 or v_slottotal<>2 or v_slotnum not in (1,2) or v_slotnum=any(v_slots) then raise exception '1台目・2台目の組合せが一致しません' using errcode='22023'; end if;
  v_slots:=pg_catalog.array_append(v_slots,v_slotnum);
  v_driver:=p_driver_ids[pg_catalog.array_position(p_request_ids,v_req.id)];
  if v_driver is null or not exists(select 1 from public.drivers d where d.id=v_driver and d.organization_id=v_company and d.status in ('available','assigned')) then raise exception '自社の利用可能な乗務員を選択してください' using errcode='22023'; end if;
  if exists(select 1 from public.assignments a join public.transport_requests r on r.id=a.request_id where a.driver_id=v_driver and r.pickup_date=v_req.pickup_date and not(a.request_id=any(p_request_ids)) and a.status not in ('done','cancelled','canceled')) then raise exception '乗務員は同日の別依頼に手配済みです' using errcode='23505'; end if;
  if exists(select 1 from public.assignments a where a.request_id=v_req.id) then raise exception '割当記録がすでにあります' using errcode='P0002'; end if;
  v_key:=coalesce(v_req.notes,'');
  v_key:=pg_catalog.regexp_replace(v_key,'車両番号：[0-9]+/[0-9]+台','車両番号：N/N台','g');
  v_key:=pg_catalog.regexp_replace(v_key,E'到着予定時刻：[^\\r\\n]*','到着予定時刻：台別','g');
  v_key:=pg_catalog.regexp_replace(v_key,E'運行時間：[^\\r\\n]*','運行時間：台別','g');
  v_key:=pg_catalog.regexp_replace(v_key,E'利用時間：[^\\r\\n]*','利用時間：台別','g');
  if v_n=1 then v_base:=v_req; v_basekey:=v_key;
  elsif v_req.venue_id is distinct from v_base.venue_id or v_req.requester_id is distinct from v_base.requester_id or v_req.pickup_date is distinct from v_base.pickup_date or v_req.pickup_location is distinct from v_base.pickup_location or v_req.destination is distinct from v_base.destination or v_req.vehicle_type is distinct from v_base.vehicle_type or v_key is distinct from v_basekey then raise exception '依頼日・運行区間・依頼内容などが異なるため一括受注できません' using errcode='22023';
  end if;
 end loop;
 if v_n<>2 or not(1=any(v_slots) and 2=any(v_slots)) then raise exception '1台目と2台目の依頼がそろっていません' using errcode='P0002'; end if;
 perform pg_catalog.set_config('wedrive.batch_accepting','on',true);
 insert into public.assignments(request_id,company_id,driver_id,status,accepted_by_name,accepted_at)
 select x.request_id,v_company,x.driver_id,'accepted',v_contact,v_at from unnest(p_request_ids,p_driver_ids) as x(request_id,driver_id);
 update public.transport_requests set status='accepted' where id=any(p_request_ids);
 return 2;
end;
$function$;
