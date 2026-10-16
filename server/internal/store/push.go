package store

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ---------- Memoria ----------

func (m *Memory) SetPushToken(_ context.Context, acc string, dev int, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := devKey{acc, dev}
	if _, ok := m.devices[k]; !ok {
		return ErrNotFound
	}
	if m.push == nil {
		m.push = map[devKey]string{}
	}
	if token == "" {
		delete(m.push, k)
		return nil
	}
	for other, t := range m.push {
		if t == token && other != k {
			delete(m.push, other)
		}
	}
	m.push[k] = token
	return nil
}

func (m *Memory) PushToken(_ context.Context, acc string, dev int) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.push[devKey{acc, dev}], nil
}

func (m *Memory) DropPushToken(_ context.Context, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, t := range m.push {
		if t == token {
			delete(m.push, k)
		}
	}
	return nil
}

// ---------- Postgres ----------
// Las filas cuelgan de devices con ON DELETE CASCADE: al re-registrarse o
// borrar la cuenta, el token desaparece solo.

func (p *Postgres) SetPushToken(ctx context.Context, acc string, dev int, token string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	if token == "" {
		_, err := p.pool.Exec(ctx, `DELETE FROM push_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev)
		return err
	}
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`DELETE FROM push_tokens WHERE token = $1 AND NOT (account_id = $2 AND device_id = $3)`,
			token, acc, dev); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO push_tokens (account_id, device_id, token, updated_at)
			SELECT account_id, device_id, $3, now() FROM devices WHERE account_id = $1 AND device_id = $2
			ON CONFLICT (account_id, device_id) DO UPDATE SET token = EXCLUDED.token, updated_at = now()`,
			acc, dev, token)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

func (p *Postgres) PushToken(ctx context.Context, acc string, dev int) (string, error) {
	if _, err := uuid.Parse(acc); err != nil {
		return "", nil
	}
	var t string
	err := p.pool.QueryRow(ctx,
		`SELECT token FROM push_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev).Scan(&t)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return t, err
}

func (p *Postgres) DropPushToken(ctx context.Context, token string) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM push_tokens WHERE token = $1`, token)
	return err
}
