CREATE INDEX content_published_text_search_idx
  ON content USING GIN (to_tsvector('simple', body::text))
  WHERE kind = 'text' AND status = 'published' AND deleted_at IS NULL;

CREATE TABLE content_report (
  id uuid PRIMARY KEY,
  reporter_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN ('spam', 'harassment', 'harmful', 'impersonation', 'other')),
  details varchar(500) NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'reviewing', 'actioned', 'dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reporter_id, content_id),
  CHECK (char_length(details) <= 500)
);

CREATE INDEX content_report_review_queue_idx ON content_report(status, created_at, id);
