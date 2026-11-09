-- Invita a tus amigos: cada cuenta tiene un código; quien se registra con él
-- cuenta como invitado. Cada 3 invitados, quien invita gana 1 mes de Plus.
CREATE TABLE IF NOT EXISTS invite_codes (
    account_id  UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    code        TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS invites (
    invitee_id  UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    inviter_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS invites_inviter ON invites (inviter_id);
