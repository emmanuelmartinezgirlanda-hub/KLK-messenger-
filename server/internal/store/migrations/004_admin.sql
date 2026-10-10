-- Panel del dueño: actividad, bloqueos, avisos y conteo de SMS.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS last_seen     TIMESTAMPTZ;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS banned_at     TIMESTAMPTZ;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS banned_reason TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS accounts_created_idx ON accounts (created_at);
CREATE INDEX IF NOT EXISTS accounts_seen_idx ON accounts (last_seen);

ALTER TABLE reports ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;

-- Avisos de KLK para todos los usuarios (los escribe el dueño).
CREATE TABLE IF NOT EXISTS announcements (
    id          UUID PRIMARY KEY,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS announcements_created_idx ON announcements (created_at);

-- Un registro por SMS enviado (solo el prefijo del país, nunca el número).
CREATE TABLE IF NOT EXISTS sms_events (
    sent_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    country  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS sms_events_sent_idx ON sms_events (sent_at);
