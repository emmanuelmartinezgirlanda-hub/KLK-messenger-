-- Tokens de notificaciones push (APNs) por dispositivo.
-- Solo sirven para que Apple despierte al iPhone: no llevan mensajes.
CREATE TABLE IF NOT EXISTS push_tokens (
    account_id  UUID    NOT NULL,
    device_id   INTEGER NOT NULL,
    token       TEXT    NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS push_tokens_token ON push_tokens (token);
