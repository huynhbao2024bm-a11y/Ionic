CREATE TABLE content_reaction (
  id uuid NOT NULL UNIQUE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  reaction text NOT NULL DEFAULT 'like' CHECK (reaction = 'like'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (content_id, user_id)
);

CREATE INDEX content_reaction_content_idx ON content_reaction(content_id, created_at DESC);

CREATE TABLE content_bookmark (
  id uuid NOT NULL UNIQUE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (content_id, user_id)
);

CREATE INDEX content_bookmark_user_idx ON content_bookmark(user_id, created_at DESC);

CREATE TABLE content_reply (
  id uuid PRIMARY KEY,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  body varchar(500) NOT NULL,
  status text NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'removed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (char_length(btrim(body)) BETWEEN 1 AND 500)
);

CREATE INDEX content_reply_timeline_idx ON content_reply(content_id, created_at, id)
  WHERE status = 'published';

ALTER TABLE user_preference_feature
  DROP CONSTRAINT IF EXISTS user_preference_feature_source_summary_check,
  DROP CONSTRAINT IF EXISTS user_preference_feature_source_summary_check1,
  ADD CONSTRAINT user_preference_feature_source_summary_nonempty CHECK (cardinality(source_summary) > 0),
  ADD CONSTRAINT user_preference_feature_source_summary_allowed
    CHECK (source_summary <@ ARRAY['like', 'unlike', 'save', 'unsave', 'follow', 'unfollow', 'comment', 'share', 'active_view', 'skip', 'more_like_this', 'less_like_this', 'hide']::text[]);
