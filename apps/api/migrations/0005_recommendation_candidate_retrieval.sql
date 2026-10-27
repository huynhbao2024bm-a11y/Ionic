CREATE INDEX content_public_text_recent_idx
  ON content(created_at DESC, id DESC)
  WHERE kind = 'text'
    AND visibility = 'public'
    AND status = 'published'
    AND deleted_at IS NULL;
