-- Release a driver after their last assignment is removed.
-- This handles assignment rows deleted directly or cascaded when an admin
-- deletes the associated transport request. It never deletes the driver's
-- WEDRIVE login or driver record.
CREATE OR REPLACE FUNCTION public.wedrive_release_driver_after_assignment_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF OLD.driver_id IS NULL THEN
    RETURN OLD;
  END IF;

  UPDATE public.drivers AS d
  SET status = 'available'
  WHERE d.id = OLD.driver_id
    AND lower(coalesce(d.status, '')) = 'assigned'
    AND NOT EXISTS (
      SELECT 1
      FROM public.assignments AS a
      LEFT JOIN public.transport_requests AS r ON r.id = a.request_id
      WHERE a.driver_id = OLD.driver_id
        AND lower(coalesce(a.status, '')) NOT IN ('done', 'completed', 'cancelled', 'canceled')
        AND (
          r.id IS NULL
          OR lower(coalesce(r.status, '')) NOT IN ('done', 'completed', 'cancelled', 'canceled')
        )
    );

  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS wedrive_release_driver_after_assignment_delete
  ON public.assignments;

CREATE TRIGGER wedrive_release_driver_after_assignment_delete
AFTER DELETE ON public.assignments
FOR EACH ROW
EXECUTE FUNCTION public.wedrive_release_driver_after_assignment_delete();
