-- A parent content deletion needs no cache update: that cache is cascading too.
-- Guard against revalidating its FK after the parent row has already vanished.
CREATE OR REPLACE FUNCTION invalidate_attention_summary() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM content WHERE id=OLD.content_id) THEN
    UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=OLD.content_id;
  END IF;
  RETURN OLD;
END;
$$;
CREATE OR REPLACE FUNCTION release_audience_grant() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM content WHERE id=OLD.content_id) THEN
    UPDATE recommendation_post_distribution SET issued_unique=greatest(0,issued_unique-1)
      WHERE content_id=OLD.content_id AND window_start=OLD.window_start;
  END IF;
  RETURN OLD;
END;
$$;
