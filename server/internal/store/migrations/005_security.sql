-- PIN de registro: protege la cuenta si alguien consigue tu SIM.
-- Solo se guarda un hash lento (PBKDF2) con su sal, nunca el PIN.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS pin_hash     BYTEA;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS pin_salt     BYTEA;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS pin_failures INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS sms_events_country_idx ON sms_events (country, sent_at);
