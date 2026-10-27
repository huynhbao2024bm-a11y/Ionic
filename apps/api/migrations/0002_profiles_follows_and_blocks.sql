CREATE TABLE account_follow (
  follower_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  followed_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, followed_id),
  CHECK (follower_id <> followed_id)
);

CREATE INDEX account_follow_followed_idx ON account_follow(followed_id, created_at DESC);

CREATE TABLE account_block (
  blocker_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

CREATE INDEX account_block_blocked_idx ON account_block(blocked_id, blocker_id);
