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
	// ClaimAppleSub ata una suscripción de Apple (originalTransactionId) a
	// una cuenta. Si ya era de otra cuenta, no la cambia y devuelve esa otra.
	ClaimAppleSub(ctx context.Context, originalTxID, accountID string, expires time.Time) (owner string, err error)
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

func (m *Memory) ClaimAppleSub(_ context.Context, otid, acc string, expires time.Time) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return "", ErrNotFound
	}
	if m.appleSubs == nil {
		m.appleSubs = map[string]string{}
	}
	if owner, ok := m.appleSubs[otid]; ok {
		if _, alive := m.accounts[owner]; alive {
			return owner, nil
		}
	}
	m.appleSubs[otid] = acc
	return acc, nil
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

func (p *Postgres) ClaimAppleSub(ctx context.Context, otid, acc string, expires time.Time) (string, error) {
	var owner string
	err := p.pool.QueryRow(ctx, `
		INSERT INTO apple_subs (original_tx_id, account_id, expires_at) VALUES ($1, $2, $3)
		ON CONFLICT (original_tx_id) DO UPDATE
		   SET expires_at = GREATEST(apple_subs.expires_at, EXCLUDED.expires_at)
		RETURNING account_id::text`, otid, acc, expires).Scan(&owner)
	return owner, err
}
