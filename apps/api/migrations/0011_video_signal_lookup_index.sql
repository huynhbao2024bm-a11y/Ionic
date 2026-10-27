CREATE INDEX recommendation_video_signal_lookup_idx
  ON recommendation_video_signal(user_id, content_id, signal_kind, created_at DESC);
