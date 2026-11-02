-- Operator-only, scoped rollback. Does not touch accounts/content or other jobs.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname='ionic-preview-healthcheck';
UPDATE ionic_ops.preview_healthcheck SET enabled=false WHERE singleton;
