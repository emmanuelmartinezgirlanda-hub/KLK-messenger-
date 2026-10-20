-- Suscripciones de KLK Plus compradas con Apple: cada una es de una sola cuenta.
CREATE TABLE IF NOT EXISTS apple_subs (
    original_tx_id TEXT PRIMARY KEY,
    account_id     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    expires_at     TIMESTAMPTZ NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
