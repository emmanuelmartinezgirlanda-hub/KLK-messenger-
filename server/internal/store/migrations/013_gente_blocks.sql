-- KLK Mi Gente: aceptar las normas antes de publicar, y bloquear a otras cuentas.
ALTER TABLE gente_profiles ADD COLUMN IF NOT EXISTS rules_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS gente_blocks (
    blocker     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    blocked     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker, blocked)
);
CREATE INDEX IF NOT EXISTS gente_blocks_blocked_idx ON gente_blocks (blocked);
