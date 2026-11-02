-- Additive. Existing sessions/accounts are preserved. Provision the confirmed
-- owner by an operator in this private table; never accept owner IDs from signup.
CREATE TABLE reserved_handle (
  handle varchar(24) PRIMARY KEY,
  owner_id uuid REFERENCES app_user(id) ON DELETE SET NULL,
  CHECK (handle = 'admin')
);
INSERT INTO reserved_handle(handle) VALUES ('admin');
ALTER TABLE reserved_handle ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON reserved_handle FROM PUBLIC;

CREATE FUNCTION enforce_new_handle_policy() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
  IF position('admin' in lower(NEW.handle)) > 0 THEN
    IF NEW.handle <> 'admin' OR NOT EXISTS (
      SELECT 1 FROM reserved_handle WHERE handle='admin' AND owner_id=NEW.id
    ) THEN
      RAISE EXCEPTION 'Handle is reserved' USING ERRCODE='23514';
    END IF;
  ELSIF length(regexp_replace(NEW.handle, '[^0-9]', '', 'g')) < 3 THEN
    RAISE EXCEPTION 'Handle requires at least three digits' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER app_user_handle_policy
  BEFORE INSERT OR UPDATE OF handle, handle_normalized ON app_user
  FOR EACH ROW EXECUTE FUNCTION enforce_new_handle_policy();
-- Roll back API first. Retain reservation and trigger to prevent name takeover;
-- do not drop this guard just to permit legacy signup. No account rename here.
