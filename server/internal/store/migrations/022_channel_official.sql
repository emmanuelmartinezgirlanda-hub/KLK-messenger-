-- Canal oficial (insignia ✅, sale el primero y lo siguen los usuarios nuevos).
ALTER TABLE channels ADD COLUMN IF NOT EXISTS official BOOLEAN NOT NULL DEFAULT false;
