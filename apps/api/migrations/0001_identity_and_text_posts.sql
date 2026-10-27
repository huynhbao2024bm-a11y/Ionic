CREATE TABLE app_user (
  id uuid PRIMARY KEY,
  handle varchar(24) NOT NULL,
  handle_normalized varchar(24) NOT NULL UNIQUE,
  password_salt bytea NOT NULL,
  password_hash bytea NOT NULL,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'suspended', 'deleted')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (handle_normalized ~ '^[a-z0-9_]{3,24}$'),
  CHECK (octet_length(password_salt) = 16),
  CHECK (octet_length(password_hash) = 64)
);

CREATE TABLE user_profile (
  user_id uuid PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
  display_name varchar(48) NOT NULL,
  bio varchar(160) NOT NULL DEFAULT '',
  visibility text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'private')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_session (
  token_hash varchar(64) PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > created_at)
);

CREATE INDEX user_session_user_expiry_idx ON user_session(user_id, expires_at);

CREATE TABLE content (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'text' CHECK (kind = 'text'),
  body varchar(280) NOT NULL,
  visibility text NOT NULL DEFAULT 'public' CHECK (visibility = 'public'),
  status text NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'removed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CHECK (char_length(btrim(body)) BETWEEN 1 AND 280)
);

CREATE INDEX content_author_timeline_idx ON content(author_id, created_at DESC, id DESC)
  WHERE status = 'published' AND deleted_at IS NULL;

CREATE TABLE content_label (
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  taxonomy_version varchar(64) NOT NULL,
  dimension text NOT NULL CHECK (dimension IN ('topic', 'format', 'language', 'context', 'lineage')),
  label_id varchar(128) NOT NULL,
  confidence real NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  source text NOT NULL CHECK (source IN ('creator', 'user_corrected', 'rule')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (content_id, taxonomy_version, dimension, label_id)
);

CREATE INDEX content_label_lookup_idx
  ON content_label(taxonomy_version, dimension, label_id, content_id)
  WHERE status = 'active';
