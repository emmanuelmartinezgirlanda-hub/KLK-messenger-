-- KLK Plus: hasta cuándo tiene Plus cada cuenta (NULL = no tiene).
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS plus_until TIMESTAMPTZ;
