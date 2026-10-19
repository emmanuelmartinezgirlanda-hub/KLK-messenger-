package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// PlusStore guarda hasta cuándo tiene KLK Plus cada cuenta.
type PlusStore interface {
	// PlusUntil devuelve la fecha de fin de Plus (cero si no tiene).
	PlusUntil(ctx context.Context, accountID string) (time.Time, error)
	SetPlusUntil(ctx context.Context, accountID string, until time.Time) error
}

// HasPlus dice si la cuenta tiene Plus activo ahora.
func HasPlus(ctx context.Context, s PlusStore, accountID string, now time.Time) bool {
	t, err := s.PlusUntil(ctx, accountID)
	return err == nil && t.After(now)
}

// ---------- Memoria ----------

func (m *Memory) PlusUntil(_ context.Context, acc string) (time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return time.Time{}, ErrNotFound
	}
	return m.plus[acc], nil
}

func (m *Memory) SetPlusUntil(_ context.Context, acc string, until time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	if m.plus == nil {
		m.plus = map[string]time.Time{}
	}
	m.plus[acc] = until
	return nil
}

// ---------- Postgres ----------

func (p *Postgres) PlusUntil(ctx context.Context, acc string) (time.Time, error) {
	var t *time.Time
	err := p.pool.QueryRow(ctx, `SELECT plus_until FROM accounts WHERE id = $1`, acc).Scan(&t)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, ErrNotFound
	}
	if err != nil || t == nil {
		return time.Time{}, err
	}
	return *t, nil
}

func (p *Postgres) SetPlusUntil(ctx context.Context, acc string, until time.Time) error {
	tag, err := p.pool.Exec(ctx, `UPDATE accounts SET plus_until = $2 WHERE id = $1`, acc, until)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
