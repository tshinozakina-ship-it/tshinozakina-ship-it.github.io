-- WEDRIVE: per-request chat; only the requester, accepted bus company, and admins can participate.
CREATE TABLE IF NOT EXISTS public.request_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.transport_requests(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_name text NOT NULL DEFAULT '利用者',
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS request_messages_thread_idx ON public.request_messages(request_id, created_at);
ALTER TABLE public.request_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.request_messages FROM anon, authenticated;
GRANT SELECT, INSERT ON public.request_messages TO authenticated;

CREATE OR REPLACE FUNCTION public.wedrive_can_access_request_chat(p_request_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.transport_requests r
    WHERE r.id = p_request_id AND (
      public.wedrive_has_role(ARRAY['運行管理スタッフ']::text[])
      OR r.requester_id = (SELECT auth.uid())
      OR EXISTS (
        SELECT 1 FROM public.assignments a
        JOIN public.profiles p ON p.organization_id = a.company_id
        JOIN public.wedrive_user_roles ur ON ur.user_id = p.id AND ur.role = 'バス会社'
        WHERE a.request_id = r.id AND p.id = (SELECT auth.uid())
      )
    )
  );
$function$;
REVOKE ALL ON FUNCTION public.wedrive_can_access_request_chat(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wedrive_can_access_request_chat(uuid) TO authenticated;

DROP POLICY IF EXISTS "request chat participants can read" ON public.request_messages;
CREATE POLICY "request chat participants can read" ON public.request_messages
  FOR SELECT TO authenticated USING (public.wedrive_can_access_request_chat(request_id));
DROP POLICY IF EXISTS "request chat participants can send" ON public.request_messages;
CREATE POLICY "request chat participants can send" ON public.request_messages
  FOR INSERT TO authenticated WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND public.wedrive_can_access_request_chat(request_id)
  );

CREATE OR REPLACE FUNCTION public.wedrive_prepare_request_message()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  NEW.sender_id := (SELECT auth.uid());
  NEW.sender_name := '利用者';
  SELECT coalesce(nullif(trim(p.name), ''), '利用者') INTO NEW.sender_name
    FROM public.profiles p WHERE p.id = NEW.sender_id;
  NEW.sender_name := coalesce(nullif(NEW.sender_name, ''), '利用者');
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS prepare_request_message ON public.request_messages;
CREATE TRIGGER prepare_request_message BEFORE INSERT ON public.request_messages
  FOR EACH ROW EXECUTE FUNCTION public.wedrive_prepare_request_message();

CREATE OR REPLACE FUNCTION public.wedrive_notify_request_message()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_requester uuid;
BEGIN
  SELECT requester_id INTO v_requester FROM public.transport_requests WHERE id = NEW.request_id;
  INSERT INTO public.notifications(user_id, request_id, title, message)
  SELECT DISTINCT recipient.user_id, NEW.request_id, '依頼チャットに新着メッセージ',
    NEW.sender_name || 'さんからメッセージが届きました：' || left(NEW.body, 160)
  FROM (
    SELECT v_requester AS user_id
    UNION SELECT user_id FROM public.wedrive_user_roles WHERE role = '運行管理スタッフ'
    UNION SELECT p.id AS user_id FROM public.assignments a
      JOIN public.profiles p ON p.organization_id = a.company_id
      JOIN public.wedrive_user_roles ur ON ur.user_id = p.id AND ur.role = 'バス会社'
      WHERE a.request_id = NEW.request_id
  ) AS recipient
  WHERE recipient.user_id IS NOT NULL AND recipient.user_id <> NEW.sender_id;
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS notify_request_message ON public.request_messages;
CREATE TRIGGER notify_request_message AFTER INSERT ON public.request_messages
  FOR EACH ROW EXECUTE FUNCTION public.wedrive_notify_request_message();
