-- Hosting-only migration. Apply as the isolated project's operator, not ionic_api.
-- One technical health request / five minutes; no user/session/engagement data.
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE SCHEMA IF NOT EXISTS ionic_ops;
REVOKE ALL ON SCHEMA ionic_ops FROM PUBLIC, anon, authenticated, ionic_api;
CREATE TABLE ionic_ops.preview_healthcheck (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  enabled boolean NOT NULL DEFAULT true,
  pending_request_id bigint,
  requested_at timestamptz,
  completed_at timestamptz,
  last_request_id bigint,
  last_http_status integer,
  last_ready boolean NOT NULL DEFAULT false,
  last_error_kind text,
  consecutive_failures integer NOT NULL DEFAULT 0 CHECK(consecutive_failures>=0)
);
ALTER TABLE ionic_ops.preview_healthcheck ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ionic_ops.preview_healthcheck FROM PUBLIC,anon,authenticated,ionic_api;
INSERT INTO ionic_ops.preview_healthcheck(singleton) VALUES(true);

CREATE FUNCTION ionic_ops.run_preview_healthcheck(enqueue boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $health$
DECLARE
  s ionic_ops.preview_healthcheck%ROWTYPE;
  response record;
  ready boolean := false;
  error_kind text;
  request_id bigint;
BEGIN
  SELECT * INTO STRICT s FROM ionic_ops.preview_healthcheck WHERE singleton FOR UPDATE;
  IF s.pending_request_id IS NOT NULL THEN
    SELECT r.status_code,r.timed_out,r.error_msg,r.content,r.created INTO response
      FROM net._http_response r WHERE r.id=s.pending_request_id LIMIT 1;
    IF FOUND THEN
      BEGIN
        ready := response.status_code=200 AND (response.content::jsonb->>'status')='ready';
      EXCEPTION WHEN invalid_text_representation THEN ready:=false;
      END;
      ready:=coalesce(ready,false);
      error_kind:=CASE WHEN ready THEN NULL WHEN response.timed_out THEN 'timeout'
        WHEN response.error_msg IS NOT NULL THEN 'transport'
        WHEN response.status_code=200 THEN 'unexpected_response' ELSE 'http_status' END;
      UPDATE ionic_ops.preview_healthcheck SET pending_request_id=NULL,
        completed_at=response.created,last_request_id=s.pending_request_id,
        last_http_status=response.status_code,last_ready=ready,last_error_kind=error_kind,
        consecutive_failures=CASE WHEN ready THEN 0 ELSE least(consecutive_failures+1,1000000) END
        WHERE singleton;
    ELSIF s.requested_at < now()-interval '2 minutes' THEN
      UPDATE ionic_ops.preview_healthcheck SET pending_request_id=NULL,completed_at=now(),
        last_request_id=s.pending_request_id,last_http_status=NULL,last_ready=false,
        last_error_kind='missing_response',consecutive_failures=least(consecutive_failures+1,1000000)
        WHERE singleton;
    END IF;
  END IF;
  SELECT * INTO STRICT s FROM ionic_ops.preview_healthcheck WHERE singleton;
  IF enqueue AND s.enabled AND s.pending_request_id IS NULL
      AND (s.requested_at IS NULL OR s.requested_at<=now()-interval '4 minutes') THEN
    request_id:=net.http_get(
      url:='https://ionic-api.onrender.com/api/v1/health/ready',
      headers:='{"Accept":"application/json","User-Agent":"Ionic-Preview-Healthcheck/1"}'::jsonb,
      timeout_milliseconds:=90000
    );
    UPDATE ionic_ops.preview_healthcheck SET pending_request_id=request_id,requested_at=now()
      WHERE singleton;
  END IF;
  -- Retain only seven days of completed logs for these exact project jobs.
  DELETE FROM cron.job_run_details WHERE ctid IN(
    SELECT d.ctid FROM cron.job_run_details d JOIN cron.job j ON j.jobid=d.jobid
    WHERE j.jobname IN('ionic-preview-healthcheck','ionic-recommendation-retention','ionic-moderation-retention')
      AND d.status IN('succeeded','failed') AND d.end_time<now()-interval '7 days'
    ORDER BY d.end_time LIMIT 2000
  );
  RETURN (SELECT jsonb_build_object('enabled',enabled,'requestedAt',requested_at,
    'completedAt',completed_at,'pending',pending_request_id IS NOT NULL,
    'httpStatus',last_http_status,'ready',last_ready,'error',last_error_kind,
    'consecutiveFailures',consecutive_failures) FROM ionic_ops.preview_healthcheck WHERE singleton);
END;
$health$;
REVOKE ALL ON FUNCTION ionic_ops.run_preview_healthcheck(boolean) FROM PUBLIC,anon,authenticated,ionic_api;
SELECT cron.schedule('ionic-preview-healthcheck','*/5 * * * *',
  'SELECT ionic_ops.run_preview_healthcheck();');
-- Retire the secondary device lease; preserve owner account and reservation.
UPDATE ionic.preview_heartbeat_account SET user_id=NULL,lease_expires_at=NULL,lease_token_hash=NULL WHERE slot=2;
-- Rollback: unschedule only ionic-preview-healthcheck and disable this singleton.
-- Keep the private state for diagnosis. Never drop pg_net or unrelated cron jobs.
