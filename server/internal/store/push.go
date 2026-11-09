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
	// VoIP: token de PushKit (solo iPhone) para que las llamadas suenen con el
	// móvil bloqueado, con la pantalla de llamada de Apple (CallKit).
	VoIP string
}

// PushStore guarda los tokens de avisos push de cada dispositivo.
type PushStore interface {
	// SetPushToken guarda el token del dispositivo. Si ese mismo token estaba en
	// otra cuenta (otro número en el mismo móvil), se quita de allí.
	SetPushToken(ctx context.Context, accountID string, deviceID int, t PushToken) error
	GetPushToken(ctx context.Context, accountID string, deviceID int) (PushToken, error)
	DeletePushToken(ctx context.Context, accountID string, deviceID int) error
	// SetVoIPToken guarda el token de llamadas (PushKit). Hace falta que el
	// dispositivo ya tenga su token normal de avisos (si no, ErrNotFound).
	SetVoIPToken(ctx context.Context, accountID string, deviceID int, token string) error
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
	t.VoIP = m.push[k].VoIP
	m.push[k] = t
	return nil
}

func (m *Memory) SetVoIPToken(_ context.Context, acc string, dev int, token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := devKey{acc, dev}
	t, ok := m.push[k]
	if !ok {
		return ErrNotFound
	}
	for other, pt := range m.push {
		if other != k && token != "" && pt.VoIP == token {
			pt.VoIP = ""
			m.push[other] = pt
		}
	}
	t.VoIP = token
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
	err := p.pool.QueryRow(ctx, `SELECT platform, token, lang, voip FROM push_tokens WHERE account_id = $1 AND device_id = $2`,
		acc, dev).Scan(&t.Platform, &t.Token, &t.Lang, &t.VoIP)
	if errors.Is(err, pgx.ErrNoRows) {
		return PushToken{}, ErrNotFound
	}
	return t, err
}

func (p *Postgres) DeletePushToken(ctx context.Context, acc string, dev int) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM push_tokens WHERE account_id = $1 AND device_id = $2`, acc, dev)
	return err
}

func (p *Postgres) SetVoIPToken(ctx context.Context, acc string, dev int, token string) error {
	if token != "" {
		if _, err := p.pool.Exec(ctx, `UPDATE push_tokens SET voip = '' WHERE voip = $1 AND NOT (account_id = $2 AND device_id = $3)`,
			token, acc, dev); err != nil {
			return err
		}
	}
	tag, err := p.pool.Exec(ctx, `UPDATE push_tokens SET voip = $3, updated_at = now() WHERE account_id = $1 AND device_id = $2`,
		acc, dev, token)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
