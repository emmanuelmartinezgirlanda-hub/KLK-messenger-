-- Adjuntos (fotos, vídeos, audios, documentos) YA CIFRADOS en el móvil.
-- El servidor guarda bytes opacos: la clave viaja dentro del mensaje cifrado.
CREATE TABLE IF NOT EXISTS attachments (
    id          UUID PRIMARY KEY,
    owner       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    data        BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS attachments_created_idx ON attachments (created_at);
