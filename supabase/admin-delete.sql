-- Allow authenticated clients to issue DELETE against requests.
-- Row-level security remains enabled; the existing
-- "wedrive requests delete by admin" policy limits affected rows
-- to users with the 運行管理スタッフ role.
GRANT DELETE ON TABLE public.transport_requests TO authenticated;
