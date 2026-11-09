-- Canales: alguien publica y quien lo sigue lo lee (como los canales de WhatsApp).
-- Son públicos: no van cifrados de punta a punta.
CREATE TABLE IF NOT EXISTS channels (
    id          UUID PRIMARY KEY,
    owner_id    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    emoji       TEXT NOT NULL DEFAULT '📢',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS channels_owner ON channels (owner_id);
CREATE TABLE IF NOT EXISTS channel_followers (
    channel_id  UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    account_id  UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    followed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, account_id)
);
CREATE INDEX IF NOT EXISTS channel_followers_account ON channel_followers (account_id);
CREATE TABLE IF NOT EXISTS channel_posts (
    id          UUID PRIMARY KEY,
    channel_id  UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    body        TEXT NOT NULL,
    image       BYTEA,                         -- foto (JPEG pequeña), opcional
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS channel_posts_channel ON channel_posts (channel_id, created_at DESC);
