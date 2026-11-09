-- Llamadas con el iPhone bloqueado: token de PushKit (VoIP) de cada dispositivo.
ALTER TABLE push_tokens ADD COLUMN IF NOT EXISTS voip TEXT NOT NULL DEFAULT '';
