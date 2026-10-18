package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// PushToken es la dirección para avisar a un móvil (APNs o FCM).
type PushToken struct {
	Platform string
	Token    string
	Lang     string
}

// PushStore guarda los tokens de avisos push de cada dispositivo.
type PushStore interface {
	// SetPushToken guarda el token del dispositivo. Si ese mismo token estaba en
	// otra cuenta (otro número en el mismo móvil), se quita de allí.
	SetPushToken(ctx context.Context, accountID string, deviceID int, t PushToken) error
	GetPushToken(ctx context.Context, accountID string, deviceID int) (PushToken, error)
	DeletePushToken(ctx context.Context, accountID string, deviceID int) error
}

// ---------- Memoria ----------

func (m *Memory) SetPushToken(_ context.Context, acc string, dev int, t PushToken) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := devKey{acc, dev}
	if _, ok := m.devices[k]; !ok {
		return ErrNotFound
	}
	if m.push == nil {
		m.push = map[devKey]PushToken{}
	}
	for other, pt := range m.push {
		if other != k && pt.Token == t.Token {
			delete(m.push, other)
		}
	}
	m.push[k] = t
	return nil
}

func (m *Memory) GetPushToken(_ context.Context, acc string, dev int) (PushToken, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.push[devKey{acc, dev}]
	if !ok {
		return PushToken{}, ErrNotFound
	}
	return t, nil
}

func (m *Memory) DeletePushToken(_ context.Context, acc string, dev int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.push, devKey{acc, dev})
	return nil
}

// ---------- Postgres ----------

func (p *Postgres) SetPushToken(ctx context.Context, acc string, dev int, t PushToken) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM push_tokens WHERE token = $1 AND NOT (account_id = $2 AND device_id = $3)`,
		t.Token, acc, dev); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `INSERT INTO push_tokens (account_id, device_id, platform, token, lang, updated_at)
		SELECT $1, $2, $3, $4, $5, $6 WHERE EXISTS (SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2)
		ON CONFLICT (account_id, device_id) DO UPDATE
		SET platform = EXCLUDED.platform, token = EXCLUDED.token, lang = EXCLUDED.lang, updated_at = EXCLUDED.updated_at`,
		acc, dev, t.Platform, t.Token, t.Lang, time.Now())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return tx.Commit(ctx)
}

func (p *Postgres) GetPushToken(ctx context.Context, acc string, dev int) (PushToken, error) {
	var t PushToken
	err := p.pool.QueryRow(ctx, `SELECT platform, token, lang FROM push_tokens WHERE account_id = $1 AND device_id = $2`,
		acc, dev).Scan(&t.Platform, &t.Token, &t.Lang)
	if errors.Is(err, pgx.ErrNoRows) {
		return PushToken{}, ErrNotFound
	}
	return t, err
}

func (p *Postgres) DeletePushToken(ctx context.Context, acc string, dev int) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM push_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev)
	return err
}
