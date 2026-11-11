-- Logo del canal (foto pequeña). logo_v sube cada vez que cambia, para que
-- los móviles sepan que tienen que bajarlo otra vez.
ALTER TABLE channels ADD COLUMN IF NOT EXISTS logo BYTEA;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS logo_v INT NOT NULL DEFAULT 0;
