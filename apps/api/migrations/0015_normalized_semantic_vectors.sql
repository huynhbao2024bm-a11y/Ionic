-- Additive performance invariant: normalized vectors permit exact dot-product
-- comparisons equivalent to cosine within floating-point precision.
-- Validate existing rows; no destructive rewrite or precision conversion.
ALTER TABLE content_semantic_feature ADD CONSTRAINT semantic_vector_unit_norm
  CHECK (abs(vector_norm(embedding)-1) < 0.00001);
