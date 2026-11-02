-- Latest owner clarification: slot 2 is a single temporary foreground lease.
-- Slot 1 remains the independently verified reserved owner.
ALTER TABLE preview_heartbeat_account ADD COLUMN lease_expires_at timestamptz;
ALTER TABLE preview_heartbeat_account ADD COLUMN lease_token_hash varchar(64);
UPDATE preview_heartbeat_account SET user_id=NULL WHERE slot=2;
ALTER TABLE preview_heartbeat_account ADD CONSTRAINT heartbeat_lease_shape CHECK(
  (lease_expires_at IS NULL AND lease_token_hash IS NULL) OR
  (slot=2 AND user_id IS NOT NULL AND lease_expires_at IS NOT NULL AND lease_token_hash ~ '^[0-9a-f]{64}$')
);
-- No heartbeat history. Expired leases are ignored and replaced on claim.
-- Account deletion must clear lease metadata with its user binding.
CREATE FUNCTION clear_deleted_heartbeat_lease() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
  IF NEW.user_id IS NULL THEN NEW.lease_expires_at=NULL;NEW.lease_token_hash=NULL; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER heartbeat_deleted_identity BEFORE UPDATE OF user_id ON preview_heartbeat_account
FOR EACH ROW EXECUTE FUNCTION clear_deleted_heartbeat_lease();
-- Rollback client/API first. No customer text/media changes.
