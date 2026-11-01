-- Additive rollout: install pgvector binaries before migration. Keep the same
-- PostgreSQL major/base. Disable semantic serving before a code rollback;
-- retain this metadata and the migration baseline until rollback is resolved.
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE content_semantic_feature (
  content_id uuid PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
  model_version varchar(96) NOT NULL,
  source_updated_at timestamptz NOT NULL,
  embedding vector(384) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX content_semantic_model_idx ON content_semantic_feature(model_version, content_id);

CREATE TABLE recommendation_item_feedback (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  preference text NOT NULL CHECK (preference IN ('more', 'less')),
  source_updated_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id, content_id)
);
CREATE INDEX recommendation_feedback_recent_idx ON recommendation_item_feedback(user_id, updated_at DESC);

ALTER TABLE user_recommendation_setting ADD COLUMN evidence_dirty boolean NOT NULL DEFAULT false;

-- Preserve legacy inference as a decaying baseline. Do not backfill likes/saves
-- after a reset or reinterpret old additive weights as exact new evidence.
CREATE TABLE user_preference_baseline (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  taxonomy_version varchar(64) NOT NULL,
  dimension text NOT NULL,
  label_id varchar(128) NOT NULL,
  score real NOT NULL,
  confidence real NOT NULL,
  source_summary text[] NOT NULL,
  updated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(user_id, taxonomy_version, dimension, label_id)
);
INSERT INTO user_preference_baseline SELECT user_id, taxonomy_version, dimension,
  label_id, score, confidence, source_summary, updated_at, expires_at FROM user_preference_feature;

CREATE TABLE user_preference_evidence (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('like', 'save')),
  taxonomy_version varchar(64) NOT NULL,
  dimension text NOT NULL CHECK (dimension IN ('topic', 'format', 'language', 'context', 'lineage')),
  label_id varchar(128) NOT NULL,
  contribution real NOT NULL CHECK (contribution BETWEEN 0 AND 1),
  confidence real NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  source_updated_at timestamptz NOT NULL,
  occurred_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL CHECK (expires_at > occurred_at),
  PRIMARY KEY(user_id, content_id, kind, taxonomy_version, dimension, label_id)
);
CREATE INDEX preference_evidence_expiry_idx ON user_preference_evidence(user_id, expires_at);
CREATE INDEX preference_evidence_content_idx ON user_preference_evidence(content_id, user_id);

CREATE FUNCTION dirty_removed_preference_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE user_recommendation_setting SET evidence_dirty = true WHERE user_id = OLD.user_id;
  RETURN OLD;
END;
$$;
CREATE TRIGGER removed_preference_evidence AFTER DELETE ON user_preference_evidence
  FOR EACH ROW EXECUTE FUNCTION dirty_removed_preference_evidence();
