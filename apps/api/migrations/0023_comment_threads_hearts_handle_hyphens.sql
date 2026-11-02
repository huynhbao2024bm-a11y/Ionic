-- Additive comments migration. Existing comments remain top-level.
ALTER TABLE content_reply ADD COLUMN parent_reply_id uuid REFERENCES content_reply(id) ON DELETE SET NULL;
ALTER TABLE content_reply ADD COLUMN thread_root_id uuid REFERENCES content_reply(id) ON DELETE SET NULL;
ALTER TABLE content_reply ADD CONSTRAINT reply_no_self_parent CHECK(parent_reply_id IS DISTINCT FROM id AND thread_root_id IS DISTINCT FROM id);
CREATE INDEX content_reply_thread_idx ON content_reply(thread_root_id,created_at DESC,id DESC) WHERE status='published';
CREATE INDEX content_reply_parent_idx ON content_reply(parent_reply_id) WHERE parent_reply_id IS NOT NULL;
CREATE TABLE content_reply_reaction (
  reply_id uuid NOT NULL REFERENCES content_reply(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(reply_id,user_id)
);
CREATE INDEX content_reply_reaction_user_idx ON content_reply_reaction(user_id,reply_id);
ALTER TABLE content_reply_reaction ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON content_reply_reaction FROM PUBLIC;
ALTER TABLE app_user DROP CONSTRAINT app_user_handle_normalized_check;
ALTER TABLE app_user ADD CONSTRAINT app_user_handle_normalized_check CHECK(handle_normalized ~ '^[a-z0-9_-]{3,24}$');
-- Rollback API/client first, retain additive thread/reaction data.
-- Keep the broadened ASCII-only handle constraint so new valid accounts can log in.
