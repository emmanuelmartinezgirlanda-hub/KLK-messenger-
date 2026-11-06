package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

// OwnerSettings guarda datos privados del dueño del panel (JSON por clave).
type OwnerSettings interface {
	// OwnerSetting devuelve el valor guardado; ErrNotFound si no hay nada.
	OwnerSetting(ctx context.Context, key string) (json.RawMessage, error)
	SetOwnerSetting(ctx context.Context, key string, value json.RawMessage) error
}

func (m *Memory) OwnerSetting(_ context.Context, key string) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.owner[key]
	if !ok {
		return nil, ErrNotFound
	}
	return append(json.RawMessage(nil), v...), nil
}

func (m *Memory) SetOwnerSetting(_ context.Context, key string, value json.RawMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.owner == nil {
		m.owner = map[string]json.RawMessage{}
	}
	m.owner[key] = append(json.RawMessage(nil), value...)
	return nil
}

func (p *Postgres) OwnerSetting(ctx context.Context, key string) (json.RawMessage, error) {
	var v []byte
	err := p.pool.QueryRow(ctx, `SELECT value FROM owner_settings WHERE key = $1`, key).Scan(&v)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return v, err
}

func (p *Postgres) SetOwnerSetting(ctx context.Context, key string, value json.RawMessage) error {
	_, err := p.pool.Exec(ctx, `INSERT INTO owner_settings (key, value, updated_at) VALUES ($1, $2, now())
		ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, key, []byte(value))
	return err
}
