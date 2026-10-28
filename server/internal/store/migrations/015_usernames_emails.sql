-- Nombre de usuario (@) para encontrar a alguien sin su número, y correo de la cuenta
-- (para entrar con correo o recuperar la cuenta si pierdes el número).
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS username TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS accounts_username_idx ON accounts (username) WHERE username IS NOT NULL;

CREATE TABLE IF NOT EXISTS account_emails (
    account_id   UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    email        TEXT NOT NULL UNIQUE,
    verified_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
