-- KLK: esquema inicial.
-- El servidor solo guarda lo mínimo para enrutar. Nunca texto en claro.

CREATE TABLE IF NOT EXISTS accounts (
    id          UUID PRIMARY KEY,
    phone       TEXT NOT NULL UNIQUE,          -- E.164, p. ej. +18095551234
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
    account_id       UUID    NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id        INTEGER NOT NULL,          -- 1 = dispositivo principal
    name             TEXT    NOT NULL DEFAULT '',
    registration_id  INTEGER NOT NULL,          -- registrationId de Signal
    identity_key     BYTEA   NOT NULL,          -- clave pública de identidad
    token_hash       BYTEA   NOT NULL UNIQUE,   -- SHA-256 del token de sesión
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id)
);

CREATE TABLE IF NOT EXISTS signed_prekeys (
    account_id  UUID    NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BYTEA   NOT NULL,
    signature   BYTEA   NOT NULL,
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
    account_id  UUID    NOT NULL,
    device_id   INTEGER NOT NULL,
    key_id      INTEGER NOT NULL,
    public_key  BYTEA   NOT NULL,
    PRIMARY KEY (account_id, device_id, key_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);

-- Cola de sobres cifrados. Se borran en cuanto el destinatario confirma (ack).
CREATE TABLE IF NOT EXISTS envelopes (
    id            UUID PRIMARY KEY,
    to_account    UUID    NOT NULL,
    to_device     INTEGER NOT NULL,
    from_account  UUID    NOT NULL,
    from_device   INTEGER NOT NULL,
    type          SMALLINT NOT NULL,            -- tipo de ciphertext de Signal
    content       BYTEA   NOT NULL,             -- ciphertext opaco
    server_ts     TIMESTAMPTZ NOT NULL,
    deliver_at    TIMESTAMPTZ NOT NULL,         -- > server_ts = mensaje programado
    FOREIGN KEY (to_account, to_device) REFERENCES devices ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS envelopes_pending_idx
    ON envelopes (to_account, to_device, deliver_at);
CREATE INDEX IF NOT EXISTS envelopes_scheduled_idx
    ON envelopes (deliver_at) WHERE deliver_at > server_ts;
