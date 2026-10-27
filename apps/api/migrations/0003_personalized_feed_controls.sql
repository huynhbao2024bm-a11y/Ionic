CREATE TABLE user_recommendation_setting (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  learning_paused boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_preference_control (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  taxonomy_version varchar(64) NOT NULL,
  dimension text NOT NULL CHECK (dimension IN ('topic', 'format', 'language', 'context', 'lineage')),
  label_id varchar(128) NOT NULL,
  control text NOT NULL CHECK (control IN ('more', 'less')),
  source text NOT NULL DEFAULT 'item_feedback' CHECK (source = 'item_feedback'),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, taxonomy_version, dimension, label_id)
);

CREATE INDEX user_preference_control_lookup_idx
  ON user_preference_control(user_id, taxonomy_version, control);

CREATE TABLE user_preference_feature (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  taxonomy_version varchar(64) NOT NULL,
  dimension text NOT NULL CHECK (dimension IN ('topic', 'format', 'language', 'context', 'lineage')),
  label_id varchar(128) NOT NULL,
  score real NOT NULL CHECK (score >= -1 AND score <= 1),
  confidence real NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  source_summary text[] NOT NULL
    CHECK (cardinality(source_summary) > 0)
    CHECK (source_summary <@ ARRAY['like', 'save', 'follow', 'unfollow', 'comment', 'share', 'active_view', 'skip', 'more_like_this', 'less_like_this', 'hide']::text[]),
  updated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, taxonomy_version, dimension, label_id),
  CHECK (expires_at > updated_at)
);

CREATE INDEX user_preference_feature_active_idx
  ON user_preference_feature(user_id, taxonomy_version, expires_at);

CREATE TABLE feed_content_hide (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, content_id)
);
