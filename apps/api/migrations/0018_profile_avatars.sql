-- Additive. Apply before the new API; old clients remain compatible.
-- Roll back API/client first. Keep this column/assets until no client uses it.
ALTER TABLE user_profile ADD COLUMN avatar_media_id uuid UNIQUE
  REFERENCES media_asset(id) ON DELETE SET NULL;
