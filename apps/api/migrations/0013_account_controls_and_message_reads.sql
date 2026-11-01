-- Additive rollout. Apply before the updated Dart API. Rollback the API first;
-- retain these tables/columns until any recovery and deletion work is drained.
ALTER TABLE user_session ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX user_session_id_idx ON user_session(id);

CREATE TABLE account_recovery_code (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  code_hash varchar(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE account_setting (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  message_permission text NOT NULL DEFAULT 'everyone'
    CHECK (message_permission IN ('everyone', 'following', 'nobody')),
  discoverable boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE direct_conversation_read (
  conversation_id uuid NOT NULL REFERENCES direct_conversation(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  last_read_at timestamptz NOT NULL,
  last_read_message_id uuid NOT NULL,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE media_deletion_job (
  storage_kind text NOT NULL CHECK (storage_kind IN ('attachment', 'video')),
  storage_key uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (storage_kind, storage_key)
);

CREATE FUNCTION enqueue_deleted_media() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO media_deletion_job(storage_kind, storage_key)
  VALUES (TG_ARGV[0], OLD.storage_key::uuid) ON CONFLICT DO NOTHING;
  RETURN OLD;
END;
$$;
CREATE TRIGGER media_asset_deletion AFTER DELETE ON media_asset
  FOR EACH ROW EXECUTE FUNCTION enqueue_deleted_media('attachment');
CREATE TRIGGER video_asset_deletion AFTER DELETE ON video_asset
  FOR EACH ROW EXECUTE FUNCTION enqueue_deleted_media('video');

-- Parent deletion removes its attachment assets too, preserving deletion jobs
-- in the same transaction (including cascades from account deletion).
CREATE FUNCTION delete_unlinked_attachment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM media_asset WHERE id = OLD.media_asset_id;
  RETURN OLD;
END;
$$;
CREATE TRIGGER content_attachment_deletion AFTER DELETE ON content_attachment
  FOR EACH ROW EXECUTE FUNCTION delete_unlinked_attachment();
