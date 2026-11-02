-- On request deletion, assignment rows cascade-delete.
-- Release the driver only when no other active assignment remains.
-- The driver record and WEDRIVE login are retained.
CREATE OR REPLACE FUNCTION public.wd_rel_drv()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF OLD.driver_id IS NOT NULL THEN
    UPDATE public.drivers
    SET status = 'available'
    WHERE id = OLD.driver_id
      AND status = 'assigned'
      AND NOT EXISTS (
        SELECT 1 FROM public.assignments
        WHERE driver_id = OLD.driver_id
          AND status = 'assigned'
      );
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS wd_rel_drv ON public.assignments;
CREATE TRIGGER wd_rel_drv
AFTER DELETE ON public.assignments
FOR EACH ROW
EXECUTE FUNCTION public.wd_rel_drv();
