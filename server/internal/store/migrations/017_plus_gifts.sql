-- KLK Plus: códigos de regalo que crea el dueño desde el panel.
-- Cada código vale una sola vez (used_at deja de ser NULL al canjearlo).
CREATE TABLE IF NOT EXISTS plus_gift_codes (
    code        TEXT PRIMARY KEY,
    days        INT NOT NULL CHECK (days > 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    used_by     UUID REFERENCES accounts(id) ON DELETE SET NULL,
    used_at     TIMESTAMPTZ
);
