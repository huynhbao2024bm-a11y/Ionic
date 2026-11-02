-- Additive reviewer permissions; provision membership privately, never by handle.
CREATE TABLE moderation_reviewer (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE moderation_reviewer ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON moderation_reviewer FROM PUBLIC;

ALTER TABLE content_report ADD COLUMN reply_id uuid REFERENCES content_reply(id) ON DELETE CASCADE;
ALTER TABLE content_report DROP CONSTRAINT content_report_reporter_id_content_id_key;
CREATE UNIQUE INDEX content_report_post_unique ON content_report(reporter_id, content_id) WHERE reply_id IS NULL;
CREATE UNIQUE INDEX content_report_reply_unique ON content_report(reporter_id, reply_id) WHERE reply_id IS NOT NULL;
CREATE INDEX content_report_target_open_idx ON content_report(content_id, reply_id) WHERE status IN ('received','reviewing');

CREATE TABLE moderation_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reviewer_id uuid REFERENCES app_user(id) ON DELETE SET NULL,
  content_id uuid REFERENCES content(id) ON DELETE CASCADE,
  reply_id uuid REFERENCES content_reply(id) ON DELETE CASCADE,
  action text NOT NULL CHECK(action IN ('remove','dismiss')),
  reason varchar(500) NOT NULL CHECK(char_length(btrim(reason)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX moderation_audit_expiry_idx ON moderation_audit(created_at);
ALTER TABLE moderation_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON moderation_audit FROM PUBLIC;
-- Roll back API first; keep queue/audit/membership. No existing report is lost.
