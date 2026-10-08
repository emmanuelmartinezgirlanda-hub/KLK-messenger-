-- Denuncias de usuarios (spam, acoso, estafas).
-- Los mensajes van cifrados de punta a punta: el servidor solo ve los que
-- el propio denunciante decide adjuntar (los últimos que recibió).
CREATE TABLE IF NOT EXISTS reports (
    id          UUID PRIMARY KEY,
    reporter    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    reported    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    reason      TEXT NOT NULL,
    messages    JSONB NOT NULL DEFAULT '[]',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reports_reported_idx ON reports (reported, created_at);
CREATE INDEX IF NOT EXISTS reports_reporter_idx ON reports (reporter, created_at);
