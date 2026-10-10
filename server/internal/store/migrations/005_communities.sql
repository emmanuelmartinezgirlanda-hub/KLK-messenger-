-- Comunidades por país: quién se ha unido a cuál (solo el id de la cuenta).
CREATE TABLE IF NOT EXISTS community_members (
    community   TEXT NOT NULL,
    account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (community, account_id)
);
CREATE INDEX IF NOT EXISTS community_members_account_idx ON community_members (account_id);
