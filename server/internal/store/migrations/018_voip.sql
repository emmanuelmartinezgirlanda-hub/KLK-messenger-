-- Llamadas con el iPhone bloqueado: token de avisos VoIP (PushKit) de cada dispositivo.
-- Solo se usa para hacer sonar una llamada entrante; el aviso no lleva nada del chat.
CREATE TABLE IF NOT EXISTS voip_tokens (
    account_id  UUID    NOT NULL,
    device_id   INTEGER NOT NULL,
    token       TEXT    NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id),
    FOREIGN KEY (account_id, device_id) REFERENCES devices ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS voip_tokens_token_idx ON voip_tokens(token);
