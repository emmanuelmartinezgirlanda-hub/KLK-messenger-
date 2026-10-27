-- KLK Mi Gente: publicaciones de «Vendo» (con precio) y marca de «Vendido».
ALTER TABLE gente_posts ADD COLUMN IF NOT EXISTS sale     BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE gente_posts ADD COLUMN IF NOT EXISTS price    DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE gente_posts ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT '';
ALTER TABLE gente_posts ADD COLUMN IF NOT EXISTS sold     BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS gente_posts_sale_idx ON gente_posts (sale, created_at DESC);
