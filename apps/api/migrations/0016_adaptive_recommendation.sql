-- Additive: deploy schema before enabling RECOMMENDATION_ADAPTIVE_ENABLED.
-- Roll back the feature flag first; retain evidence until expiry/cleanup.
ALTER TABLE user_recommendation_setting ADD COLUMN delivery_sequence bigint NOT NULL DEFAULT 0;

CREATE TABLE recommendation_feed_plan (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  page_size int NOT NULL CHECK(page_size BETWEEN 1 AND 50),
  seed varchar(32) NOT NULL,
  delivered_ids uuid[] NOT NULL DEFAULT '{}',
  delivered_keys text[] NOT NULL DEFAULT '{}',
  pages jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(pages)='array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours',
  CHECK(expires_at>created_at AND expires_at<=created_at+interval '24 hours'),
  CHECK(cardinality(delivered_ids)<=1000 AND cardinality(delivered_keys)<=1000)
);
CREATE INDEX recommendation_plan_owner_idx ON recommendation_feed_plan(user_id,created_at DESC);
CREATE INDEX recommendation_plan_expiry_idx ON recommendation_feed_plan(expires_at);

CREATE TABLE recommendation_delivery_receipt (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  plan_id uuid REFERENCES recommendation_feed_plan(id) ON DELETE SET NULL,
  source_updated_at timestamptz NOT NULL,
  delivery_sequence bigint NOT NULL,
  topic_ids text[] NOT NULL DEFAULT '{}',
  text_characters int NOT NULL CHECK(text_characters BETWEEN 0 AND 10000),
  has_media boolean NOT NULL,
  is_random boolean NOT NULL,
  measurement_enabled boolean NOT NULL,
  attention_band smallint NOT NULL DEFAULT -1 CHECK(attention_band BETWEEN -1 AND 3),
  observed_at timestamptz,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
  CHECK(expires_at>issued_at AND expires_at<=issued_at+interval '7 days')
);
CREATE INDEX recommendation_receipt_owner_idx ON recommendation_delivery_receipt(user_id,issued_at DESC);
CREATE INDEX recommendation_receipt_content_idx ON recommendation_delivery_receipt(content_id,user_id);
CREATE INDEX recommendation_receipt_expiry_idx ON recommendation_delivery_receipt(expires_at);

-- One bounded derived contribution per viewer/content/day, not an event log.
-- Keep random-reader reward separate from later personalized-reader outcomes.
CREATE TABLE recommendation_attention_summary (
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  summary_day date NOT NULL,
  source_updated_at timestamptz NOT NULL,
  topic_ids text[] NOT NULL DEFAULT '{}',
  reward real NOT NULL CHECK(reward BETWEEN 0 AND 1),
  random_reward real CHECK(random_reward BETWEEN 0 AND 1),
  last_sequence bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now()+interval '30 days',
  PRIMARY KEY(user_id,content_id,summary_day),
  CHECK(expires_at>updated_at AND expires_at<=updated_at+interval '30 days')
);
CREATE INDEX recommendation_summary_owner_idx ON recommendation_attention_summary(user_id,updated_at DESC);
CREATE INDEX recommendation_summary_content_idx ON recommendation_attention_summary(content_id,user_id);
CREATE INDEX recommendation_summary_expiry_idx ON recommendation_attention_summary(expires_at);

CREATE TABLE recommendation_post_distribution (
  content_id uuid PRIMARY KEY REFERENCES content(id) ON DELETE CASCADE,
  source_updated_at timestamptz NOT NULL,
  window_start timestamptz NOT NULL,
  allowance int NOT NULL CHECK(allowance BETWEEN 1 AND 10000),
  issued_unique int NOT NULL DEFAULT 0 CHECK(issued_unique>=0),
  dirty boolean NOT NULL DEFAULT true,
  valid_until timestamptz NOT NULL DEFAULT now(),
  score real NOT NULL DEFAULT 0.5 CHECK(score BETWEEN 0 AND 1),
  confidence real NOT NULL DEFAULT 0 CHECK(confidence BETWEEN 0 AND 1)
);
CREATE TABLE recommendation_audience_grant (
  content_id uuid NOT NULL REFERENCES content(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  window_start timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(content_id,user_id,window_start),
  CHECK(expires_at>window_start AND expires_at<=window_start+interval '24 hours')
);
CREATE INDEX recommendation_grant_owner_idx ON recommendation_audience_grant(user_id);
CREATE INDEX recommendation_grant_expiry_idx ON recommendation_audience_grant(expires_at);

CREATE FUNCTION invalidate_attention_summary() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=OLD.content_id;
  RETURN OLD;
END;
$$;
CREATE TRIGGER removed_attention_summary AFTER DELETE ON recommendation_attention_summary
  FOR EACH ROW EXECUTE FUNCTION invalidate_attention_summary();
CREATE FUNCTION release_audience_grant() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE recommendation_post_distribution SET issued_unique=greatest(0,issued_unique-1)
    WHERE content_id=OLD.content_id AND window_start=OLD.window_start;
  RETURN OLD;
END;
$$;
CREATE TRIGGER removed_audience_grant AFTER DELETE ON recommendation_audience_grant
  FOR EACH ROW EXECUTE FUNCTION release_audience_grant();
