-- Two operator-fixed preview identities only. Empty slots do not self-enroll.
CREATE TABLE preview_heartbeat_account (
  slot smallint PRIMARY KEY CHECK(slot IN (1,2)),
  user_id uuid UNIQUE REFERENCES app_user(id) ON DELETE SET NULL
);
INSERT INTO preview_heartbeat_account(slot) VALUES(1),(2);
ALTER TABLE preview_heartbeat_account ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON preview_heartbeat_account FROM PUBLIC;
-- Rollback API first, keep the fixed slots. No analytics or heartbeat history.
