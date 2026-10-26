package store

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// BusinessImage es el logo de un negocio o la foto de un producto.
// Es pública (igual que el catálogo) y no caduca.
type BusinessImage struct {
	ID        string
	Owner     string
	Mime      string
	Data      []byte
	CreatedAt time.Time
}

// BusinessImageStore guarda las fotos de los negocios.
type BusinessImageStore interface {
	PutBusinessImage(ctx context.Context, img BusinessImage) error
	GetBusinessImage(ctx context.Context, id string) (BusinessImage, error)
	CountBusinessImages(ctx context.Context, owner string) (int, error)
	// PruneBusinessImages borra las fotos de [owner] que no están en [keep]
	// y se subieron antes de [before] (las recién subidas aún no se han guardado
	// en el perfil). Devuelve cuántas borró.
	PruneBusinessImages(ctx context.Context, owner string, keep map[string]bool, before time.Time) (int, error)
	ImageExists(ctx context.Context, kind, id string) (bool, error)
}

// ---------- Memoria ----------

func (m *Memory) PutBusinessImage(_ context.Context, img BusinessImage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[img.Owner]; !ok {
		return ErrNotFound
	}
	if m.bizImages == nil {
		m.bizImages = map[string]BusinessImage{}
	}
	img.Data = append([]byte(nil), img.Data...)
	if img.CreatedAt.IsZero() {
		img.CreatedAt = time.Now()
	}
	m.bizImages[img.ID] = img
	return nil
}

func (m *Memory) GetBusinessImage(_ context.Context, id string) (BusinessImage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	img, ok := m.bizImages[id]
	if !ok {
		return BusinessImage{}, ErrNotFound
	}
	if _, ok := m.accounts[img.Owner]; !ok || m.bannedLocked(img.Owner) {
		return BusinessImage{}, ErrNotFound
	}
	return img, nil
}

func (m *Memory) CountBusinessImages(_ context.Context, owner string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, img := range m.bizImages {
		if img.Owner == owner {
			n++
		}
	}
	return n, nil
}

func (m *Memory) PruneBusinessImages(_ context.Context, owner string, keep map[string]bool, before time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for id, img := range m.bizImages {
		if img.Owner == owner && !keep[id] && img.CreatedAt.Before(before) {
			delete(m.bizImages, id)
			n++
		}
	}
	return n, nil
}

// ---------- Postgres ----------

func (p *Postgres) PutBusinessImage(ctx context.Context, img BusinessImage) error {
	if _, err := uuid.Parse(img.Owner); err != nil {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx,
		`INSERT INTO business_images (id, owner, mime, data) VALUES ($1, $2, $3, $4)`,
		img.ID, img.Owner, img.Mime, nonNil(img.Data))
	return err
}

func (p *Postgres) GetBusinessImage(ctx context.Context, id string) (BusinessImage, error) {
	if _, err := uuid.Parse(id); err != nil {
		return BusinessImage{}, ErrNotFound
	}
	var img BusinessImage
	err := p.pool.QueryRow(ctx, `
		SELECT i.id::text, i.owner::text, i.mime, i.data, i.created_at
		FROM business_images i JOIN accounts a ON a.id = i.owner
		WHERE i.id = $1 AND a.banned_at IS NULL`, id).
		Scan(&img.ID, &img.Owner, &img.Mime, &img.Data, &img.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return BusinessImage{}, ErrNotFound
	}
	return img, err
}

func (p *Postgres) CountBusinessImages(ctx context.Context, owner string) (int, error) {
	if _, err := uuid.Parse(owner); err != nil {
		return 0, nil
	}
	var n int
	err := p.pool.QueryRow(ctx, `SELECT count(*) FROM business_images WHERE owner = $1`, owner).Scan(&n)
	return n, err
}

func (p *Postgres) PruneBusinessImages(ctx context.Context, owner string, keep map[string]bool, before time.Time) (int, error) {
	if _, err := uuid.Parse(owner); err != nil {
		return 0, nil
	}
	ids := make([]string, 0, len(keep))
	for id := range keep {
		if _, err := uuid.Parse(id); err == nil {
			ids = append(ids, id)
		}
	}
	tag, err := p.pool.Exec(ctx, `
		DELETE FROM business_images
		WHERE owner = $1 AND created_at < $2 AND NOT (id::text = ANY($3))`, owner, before, ids)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// nonNil: en R2 la ficha va sin bytes, pero la columna no admite NULL.
func nonNil(b []byte) []byte {
	if b == nil {
		return []byte{}
	}
	return b
}

// ImageExists dice si queda la ficha de una foto (kind = "biz" o "gente"),
// aunque su dueño esté bloqueado. Sirve para limpiar los archivos de R2 huérfanos.
func (m *Memory) ImageExists(_ context.Context, kind, id string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch kind {
	case "biz":
		_, ok := m.bizImages[id]
		return ok, nil
	case "gente":
		if m.gent == nil {
			return false, nil
		}
		_, ok := m.gent.images[id]
		return ok, nil
	}
	return false, nil
}

func (p *Postgres) ImageExists(ctx context.Context, kind, id string) (bool, error) {
	if _, err := uuid.Parse(id); err != nil {
		return false, nil
	}
	table := map[string]string{"biz": "business_images", "gente": "gente_images"}[kind]
	if table == "" {
		return false, nil
	}
	var ok bool
	err := p.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM `+table+` WHERE id = $1)`, id).Scan(&ok)
	return ok, err
}
