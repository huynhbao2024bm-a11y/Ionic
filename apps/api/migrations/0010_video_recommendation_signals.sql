CREATE TABLE recommendation_video_signal (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  event_id uuid NOT NULL,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  signal_kind text NOT NULL CHECK (signal_kind IN ('active_view', 'skip')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  PRIMARY KEY (user_id, event_id),
  CHECK (expires_at > created_at)
);

CREATE INDEX recommendation_video_signal_expiry_idx
  ON recommendation_video_signal(user_id, expires_at);
