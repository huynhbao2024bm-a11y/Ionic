CREATE TABLE media_asset (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  storage_key varchar(36) NOT NULL UNIQUE,
  media_type text NOT NULL CHECK (media_type IN ('image', 'audio')),
  mime_type text NOT NULL CHECK (mime_type IN ('image/jpeg', 'audio/wav')),
  byte_size bigint NOT NULL CHECK (byte_size > 0),
  width integer,
  height integer,
  duration_ms integer,
  processing_state text NOT NULL DEFAULT 'ready'
    CHECK (processing_state IN ('staged', 'ready', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (media_type = 'image' AND mime_type = 'image/jpeg' AND width BETWEEN 1 AND 8192
      AND height BETWEEN 1 AND 8192 AND width::bigint * height::bigint <= 16777216
      AND duration_ms IS NULL)
    OR
    (media_type = 'audio' AND mime_type = 'audio/wav' AND width IS NULL AND height IS NULL
      AND duration_ms BETWEEN 1000 AND 60000)
  )
);

CREATE INDEX media_asset_staged_cleanup_idx ON media_asset(created_at, id)
  WHERE processing_state = 'staged';

CREATE TABLE content_attachment (
  media_asset_id uuid PRIMARY KEY REFERENCES media_asset(id) ON DELETE CASCADE,
  content_id uuid REFERENCES content(id) ON DELETE CASCADE,
  reply_id uuid REFERENCES content_reply(id) ON DELETE CASCADE,
  position smallint NOT NULL CHECK (position BETWEEN 0 AND 3),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((content_id IS NOT NULL)::integer + (reply_id IS NOT NULL)::integer = 1)
);

CREATE UNIQUE INDEX content_attachment_content_position_idx
  ON content_attachment(content_id, position) WHERE content_id IS NOT NULL;
CREATE UNIQUE INDEX content_attachment_reply_position_idx
  ON content_attachment(reply_id, position) WHERE reply_id IS NOT NULL;
CREATE INDEX content_attachment_content_idx ON content_attachment(content_id, position)
  WHERE content_id IS NOT NULL;
CREATE INDEX content_attachment_reply_idx ON content_attachment(reply_id, position)
  WHERE reply_id IS NOT NULL;
