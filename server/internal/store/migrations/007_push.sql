-- Avisos push (APNs/FCM): un token por dispositivo. El aviso nunca lleva el mensaje.
CREATE TABLE IF NOT EXISTS push_tokens (
    account_id  UUID    NOT NULL,
    device_id   INTEGER NOT NULL,
    platform    TEXT    NOT NULL,           -- "apns" (iPhone) o "fcm" (Android)
    token       TEXT    NOT NULL,
    lang        TEXT    NOT NULL DEFAULT 'es',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS push_tokens_token_idx ON push_tokens(token);
