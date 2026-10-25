-- KLK Business: logo y fotos de productos. Son PÚBLICAS (como el catálogo),
-- pequeñas (la app las reduce antes de subirlas) y no caducan.
CREATE TABLE IF NOT EXISTS business_images (
    id          UUID PRIMARY KEY,
    owner       UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    mime        TEXT NOT NULL,
    data        BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS business_images_owner_idx ON business_images (owner);
