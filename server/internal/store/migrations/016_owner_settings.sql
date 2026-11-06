-- Ajustes privados del dueño (por ejemplo, la lista de gastos y suscripciones del panel).
CREATE TABLE IF NOT EXISTS owner_settings (
    key         TEXT PRIMARY KEY,
    value       JSONB NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
