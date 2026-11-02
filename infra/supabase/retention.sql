-- Run with the isolated Ionic project's administrative connection, after the
-- application migrations. This job retains no credentials or source content.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;
SELECT cron.schedule('ionic-recommendation-retention','*/5 * * * *',$retention$
DELETE FROM ionic.recommendation_feed_plan WHERE ctid IN(SELECT ctid FROM ionic.recommendation_feed_plan WHERE expires_at<=now() ORDER BY expires_at LIMIT 2000);
DELETE FROM ionic.recommendation_delivery_receipt WHERE ctid IN(SELECT ctid FROM ionic.recommendation_delivery_receipt WHERE expires_at<=now() ORDER BY expires_at LIMIT 2000);
DELETE FROM ionic.recommendation_attention_summary WHERE ctid IN(SELECT ctid FROM ionic.recommendation_attention_summary WHERE expires_at<=now() ORDER BY expires_at LIMIT 2000);
DELETE FROM ionic.recommendation_audience_grant WHERE ctid IN(SELECT ctid FROM ionic.recommendation_audience_grant WHERE expires_at<=now() ORDER BY expires_at LIMIT 2000);
$retention$);
-- Separate bounded operational review retention, including when the API sleeps.
SELECT cron.schedule('ionic-moderation-retention','*/5 * * * *',$moderation$
UPDATE ionic.preview_heartbeat_account SET user_id=NULL,lease_expires_at=NULL,lease_token_hash=NULL WHERE slot=2 AND lease_expires_at<=now();
DELETE FROM ionic.content_report WHERE ctid IN(SELECT ctid FROM ionic.content_report WHERE created_at<=now()-interval '30 days' ORDER BY created_at LIMIT 2000);
DELETE FROM ionic.moderation_audit WHERE ctid IN(SELECT ctid FROM ionic.moderation_audit WHERE created_at<=now()-interval '30 days' ORDER BY created_at LIMIT 2000);
$moderation$);
