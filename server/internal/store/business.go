package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Business es el perfil PÚBLICO de una cuenta de negocio (colmado, peluquería…).
// Lo publica el propio dueño desde la app; cualquiera con KLK lo puede ver y buscar.
// Data guarda el resto (horario, dirección, catálogo…) tal cual lo manda la app.
type Business struct {
	AccountID string          `json:"id"`
	Name      string          `json:"name"`
	Kind      string          `json:"kind"`
	Country   string          `json:"country"`
	City      string          `json:"city"`
	Data      json.RawMessage `json:"data"`
	Verified  bool            `json:"verified"`
	UpdatedAt time.Time       `json:"updatedAt"`
}

// BusinessQuery filtra la búsqueda de negocios (campos vacíos = sin filtro).
type BusinessQuery struct {
	Text    string // en el nombre o la ciudad
	Kind    string
	Country string
	Limit   int
}

// BusinessStore guarda los perfiles de negocio.
type BusinessStore interface {
	PutBusiness(ctx context.Context, b Business) error
	// GetBusiness devuelve ErrNotFound si no hay negocio (o la cuenta está bloqueada).
	GetBusiness(ctx context.Context, accountID string) (Business, error)
	DeleteBusiness(ctx context.Context, accountID string) error
	SearchBusinesses(ctx context.Context, q BusinessQuery) ([]Business, error)
	SetBusinessVerified(ctx context.Context, accountID string, verified bool) error
}

func (q BusinessQuery) limit() int {
	if q.Limit <= 0 || q.Limit > 100 {
		return 50
	}
	return q.Limit
}

// ---------- Memoria ----------

func (m *Memory) PutBusiness(_ context.Context, b Business) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[b.AccountID]; !ok {
		return ErrNotFound
	}
	if m.business == nil {
		m.business = map[string]Business{}
	}
	if old, ok := m.business[b.AccountID]; ok {
		b.Verified = old.Verified // la verificación solo la cambia el dueño de KLK
	} else {
		b.Verified = false
	}
	m.business[b.AccountID] = b
	return nil
}

func (m *Memory) GetBusiness(_ context.Context, acc string) (Business, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.business[acc]
	if !ok || m.bannedLocked(acc) {
		return Business{}, ErrNotFound
	}
	return b, nil
}

func (m *Memory) DeleteBusiness(_ context.Context, acc string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.business, acc)
	return nil
}

func (m *Memory) SearchBusinesses(_ context.Context, q BusinessQuery) ([]Business, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	text := strings.ToLower(strings.TrimSpace(q.Text))
	out := []Business{}
	for acc, b := range m.business {
		if m.bannedLocked(acc) {
			continue
		}
		if q.Kind != "" && b.Kind != q.Kind {
			continue
		}
		if q.Country != "" && b.Country != q.Country {
			continue
		}
		if text != "" && !strings.Contains(strings.ToLower(b.Name), text) && !strings.Contains(strings.ToLower(b.City), text) {
			continue
		}
		out = append(out, b)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Verified != out[j].Verified {
			return out[i].Verified
		}
		return out[i].UpdatedAt.After(out[j].UpdatedAt)
	})
	if len(out) > q.limit() {
		out = out[:q.limit()]
	}
	return out, nil
}

func (m *Memory) SetBusinessVerified(_ context.Context, acc string, v bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.business[acc]
	if !ok {
		return ErrNotFound
	}
	b.Verified = v
	m.business[acc] = b
	return nil
}

// ---------- Postgres ----------

func (p *Postgres) PutBusiness(ctx context.Context, b Business) error {
	if _, err := uuid.Parse(b.AccountID); err != nil {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx, `
		INSERT INTO businesses (account_id, name, kind, country, city, data, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (account_id) DO UPDATE SET
		  name = EXCLUDED.name, kind = EXCLUDED.kind, country = EXCLUDED.country,
		  city = EXCLUDED.city, data = EXCLUDED.data, updated_at = EXCLUDED.updated_at`,
		b.AccountID, b.Name, b.Kind, b.Country, b.City, []byte(b.Data), b.UpdatedAt)
	return err
}

const bizCols = `b.account_id::text, b.name, b.kind, b.country, b.city, b.data, b.verified, b.updated_at`

func scanBiz(row pgx.Row) (Business, error) {
	var b Business
	var data []byte
	err := row.Scan(&b.AccountID, &b.Name, &b.Kind, &b.Country, &b.City, &data, &b.Verified, &b.UpdatedAt)
	b.Data = data
	return b, err
}

func (p *Postgres) GetBusiness(ctx context.Context, acc string) (Business, error) {
	if _, err := uuid.Parse(acc); err != nil {
		return Business{}, ErrNotFound
	}
	b, err := scanBiz(p.pool.QueryRow(ctx, `
		SELECT `+bizCols+` FROM businesses b JOIN accounts a ON a.id = b.account_id
		WHERE b.account_id = $1 AND a.banned_at IS NULL`, acc))
	if errors.Is(err, pgx.ErrNoRows) {
		return Business{}, ErrNotFound
	}
	return b, err
}

func (p *Postgres) DeleteBusiness(ctx context.Context, acc string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return nil
	}
	_, err := p.pool.Exec(ctx, `DELETE FROM businesses WHERE account_id = $1`, acc)
	return err
}

func (p *Postgres) SearchBusinesses(ctx context.Context, q BusinessQuery) ([]Business, error) {
	text := strings.TrimSpace(q.Text)
	like := "%" + strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`).Replace(text) + "%"
	rows, err := p.pool.Query(ctx, `
		SELECT `+bizCols+` FROM businesses b JOIN accounts a ON a.id = b.account_id
		WHERE a.banned_at IS NULL
		  AND ($1 = '' OR b.kind = $1)
		  AND ($2 = '' OR b.country = $2)
		  AND ($3 = '' OR b.name ILIKE $4 OR b.city ILIKE $4)
		ORDER BY b.verified DESC, b.updated_at DESC
		LIMIT $5`, q.Kind, q.Country, text, like, q.limit())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Business{}
	for rows.Next() {
		b, err := scanBiz(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (p *Postgres) SetBusinessVerified(ctx context.Context, acc string, v bool) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `UPDATE businesses SET verified = $2 WHERE account_id = $1`, acc, v)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
