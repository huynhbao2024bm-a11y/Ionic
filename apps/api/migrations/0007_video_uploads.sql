ALTER TABLE content DROP CONSTRAINT content_kind_check;
ALTER TABLE content ADD CONSTRAINT content_kind_check CHECK (kind IN ('text', 'short_video'));
ALTER TABLE content DROP CONSTRAINT content_status_check;
ALTER TABLE content ADD CONSTRAINT content_status_check CHECK (status IN ('processing', 'published', 'removed'));

CREATE INDEX content_video_timeline_idx ON content(created_at DESC, id DESC)
  WHERE kind = 'short_video' AND visibility = 'public' AND status = 'published' AND deleted_at IS NULL;

CREATE TABLE video_asset (
  content_id uuid PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
  storage_key varchar(36) NOT NULL UNIQUE,
  mime_type text NOT NULL CHECK (mime_type IN ('video/webm', 'video/mp4')),
  byte_size bigint NOT NULL CHECK (byte_size > 0),
  state text NOT NULL DEFAULT 'pending_review' CHECK (state IN ('pending_review', 'ready', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now()
);
