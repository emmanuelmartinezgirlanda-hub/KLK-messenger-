package store

import (
	"context"
	"time"
)

// CallInvite es lo poco que el servidor sabe de una llamada que empieza
// (el resto va cifrado): para hacer sonar el iPhone aunque esté bloqueado.
type CallInvite struct {
	ID    string // id de la llamada (lo inventa quien llama)
	Video bool
	From  string // cuenta de quien llama
}

// VoIPStore guarda el token de avisos VoIP (PushKit) de cada dispositivo.
type VoIPStore interface {
	SetVoIPToken(ctx context.Context, accountID string, deviceID int, token string) error
	GetVoIPToken(ctx context.Context, accountID string, deviceID int) (string, error)
	DeleteVoIPToken(ctx context.Context, accountID string, deviceID int) error
}

// ---------- Memoria ----------

func (m *Memory) SetVoIPToken(_ context.Context, acc string, dev int, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := devKey{acc, dev}
	if _, ok := m.devices[k]; !ok {
		return ErrNotFound
	}
	if m.voip == nil {
		m.voip = map[devKey]string{}
	}
	for other, t := range m.voip {
		if other != k && t == token {
			delete(m.voip, other)
		}
	}
	m.voip[k] = token
	return nil
}

func (m *Memory) GetVoIPToken(_ context.Context, acc string, dev int) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.voip[devKey{acc, dev}]
	if !ok {
		return "", ErrNotFound
	}
	return t, nil
}

func (m *Memory) DeleteVoIPToken(_ context.Context, acc string, dev int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.voip, devKey{acc, dev})
	return nil
}

// ---------- Postgres ----------

func (p *Postgres) SetVoIPToken(ctx context.Context, acc string, dev int, token string) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `DELETE FROM voip_tokens WHERE token = $1 AND NOT (account_id = $2 AND device_id = $3)`,
		token, acc, dev); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `INSERT INTO voip_tokens (account_id, device_id, token, updated_at)
		SELECT $1, $2, $3, $4 WHERE EXISTS (SELECT 1 FROM devices WHERE account_id = $1 AND device_id = $2)
		ON CONFLICT (account_id, device_id) DO UPDATE
		SET token = EXCLUDED.token, updated_at = EXCLUDED.updated_at`,
		acc, dev, token, time.Now())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return tx.Commit(ctx)
}

func (p *Postgres) GetVoIPToken(ctx context.Context, acc string, dev int) (string, error) {
	var t string
	err := p.pool.QueryRow(ctx, `SELECT token FROM voip_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev).Scan(&t)
	return t, notFound(err)
}

func (p *Postgres) DeleteVoIPToken(ctx context.Context, acc string, dev int) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM voip_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev)
	return err
}
