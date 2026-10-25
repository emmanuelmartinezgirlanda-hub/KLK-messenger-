-- KLK Mi Gente: el muro público dentro de KLK (publicaciones, me gusta y comentarios).
-- A diferencia de los chats, esto NO va cifrado: es público para la gente de KLK.
CREATE TABLE IF NOT EXISTS gente_profiles (
    account_id  UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    name        TEXT NOT NULL DEFAULT '',
    photo       TEXT NOT NULL DEFAULT '',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gente_posts (
    id          UUID PRIMARY KEY,
    author      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    country     TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT '',
    photos      JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gente_posts_time_idx ON gente_posts (created_at DESC);
CREATE INDEX IF NOT EXISTS gente_posts_country_idx ON gente_posts (country, created_at DESC);
CREATE INDEX IF NOT EXISTS gente_posts_author_idx ON gente_posts (author, created_at DESC);

CREATE TABLE IF NOT EXISTS gente_likes (
    post        UUID NOT NULL REFERENCES gente_posts(id) ON DELETE CASCADE,
    account     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post, account)
);

CREATE TABLE IF NOT EXISTS gente_comments (
    id          UUID PRIMARY KEY,
    post        UUID NOT NULL REFERENCES gente_posts(id) ON DELETE CASCADE,
    author      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gente_comments_post_idx ON gente_comments (post, created_at);

CREATE TABLE IF NOT EXISTS gente_images (
    id          UUID PRIMARY KEY,
    owner       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    mime        TEXT NOT NULL,
    data        BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gente_images_owner_idx ON gente_images (owner);
