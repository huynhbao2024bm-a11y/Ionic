CREATE TABLE account_mute (
  muter_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  muted_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (muter_id, muted_id),
  CHECK (muter_id <> muted_id)
);

CREATE INDEX account_mute_muted_idx ON account_mute(muted_id, muter_id);
