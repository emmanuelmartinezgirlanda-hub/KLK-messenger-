-- Recargas de móvil a RD (Claro, Altice, Viva).
-- Se paga con tarjeta (Stripe) y el proveedor (Reloadly) pone el saldo.
CREATE TABLE IF NOT EXISTS topups (
    id            UUID PRIMARY KEY,
    account_id    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    phone         TEXT NOT NULL,
    operator_id   BIGINT NOT NULL DEFAULT 0,
    operator_name TEXT NOT NULL DEFAULT '',
    local_amount  NUMERIC(12,2) NOT NULL,
    local_currency TEXT NOT NULL DEFAULT 'DOP',
    price_cents   BIGINT NOT NULL,
    cost_cents    BIGINT NOT NULL DEFAULT 0,
    currency      TEXT NOT NULL,
    status        TEXT NOT NULL,
    payment_ref   TEXT NOT NULL DEFAULT '',
    payment_intent TEXT NOT NULL DEFAULT '',
    provider_ref  TEXT NOT NULL DEFAULT '',
    error         TEXT NOT NULL DEFAULT '',
    test          BOOLEAN NOT NULL DEFAULT false,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS topups_account_idx ON topups (account_id, created_at);
CREATE INDEX IF NOT EXISTS topups_created_idx ON topups (created_at);
CREATE UNIQUE INDEX IF NOT EXISTS topups_payment_ref_idx ON topups (payment_ref) WHERE payment_ref <> '';
