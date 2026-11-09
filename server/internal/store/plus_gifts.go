package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// PlusAccount es una cuenta con Plus activo, para el panel del dueño.
type PlusAccount struct {
	AccountView
	PlusUntil time.Time `json:"plusUntil"`
}

// GiftCode es un código de regalo de KLK Plus. Vale una sola vez.
type GiftCode struct {
	Code      string     `json:"code"`
	Days      int        `json:"days"`
	CreatedAt time.Time  `json:"createdAt"`
	UsedBy    string     `json:"usedBy,omitempty"` // teléfono de quien lo canjeó
	UsedAt    *time.Time `json:"usedAt,omitempty"`
}

// ErrCodeExists: ya hay un código de regalo con ese texto.
var ErrCodeExists = errors.New("el código ya existe")

// PlusAdminStore es lo que el panel necesita para gestionar Plus.
type PlusAdminStore interface {
	// PlusAccounts lista las cuentas con Plus activo en [now].
	PlusAccounts(ctx context.Context, now time.Time, limit int) ([]PlusAccount, error)
	// AddGiftCode guarda un código nuevo de [days] días.
	AddGiftCode(ctx context.Context, code string, days int, at time.Time) error
	// UseGiftCode gasta el código para la cuenta y dice cuántos días da.
	// ErrNotFound si no existe o ya se usó.
	UseGiftCode(ctx context.Context, code, accountID string, at time.Time) (int, error)
	// GiftCodes lista los últimos códigos creados.
	GiftCodes(ctx context.Context, limit int) ([]GiftCode, error)
}

// ---------- Memoria ----------

type memGift struct {
	days    int
	created time.Time
	usedBy  string
	usedAt  *time.Time
}

func (m *Memory) PlusAccounts(_ context.Context, now time.Time, limit int) ([]PlusAccount, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []PlusAccount{}
	for id, until := range m.plus {
		if _, ok := m.accounts[id]; ok && until.After(now) {
			out = append(out, PlusAccount{AccountView: m.accountViewLocked(id), PlusUntil: until})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PlusUntil.After(out[j].PlusUntil) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) AddGiftCode(_ context.Context, code string, days int, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.gifts == nil {
		m.gifts = map[string]*memGift{}
	}
	if _, ok := m.gifts[code]; ok {
		return ErrCodeExists
	}
	m.gifts[code] = &memGift{days: days, created: at}
	return nil
}

func (m *Memory) UseGiftCode(_ context.Context, code, acc string, at time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g, ok := m.gifts[code]
	if !ok || g.usedAt != nil {
		return 0, ErrNotFound
	}
	if _, ok := m.accounts[acc]; !ok {
		return 0, ErrNotFound
	}
	t := at
	g.usedBy, g.usedAt = acc, &t
	return g.days, nil
}

func (m *Memory) GiftCodes(_ context.Context, limit int) ([]GiftCode, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []GiftCode{}
	for code, g := range m.gifts {
		v := GiftCode{Code: code, Days: g.days, CreatedAt: g.created, UsedAt: g.usedAt}
		if a, ok := m.accounts[g.usedBy]; ok {
			v.UsedBy = a.Phone
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ---------- Postgres ----------

func (p *Postgres) PlusAccounts(ctx context.Context, now time.Time, limit int) ([]PlusAccount, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+accountViewCols+`, a.plus_until FROM accounts a
		WHERE a.plus_until > $1 ORDER BY a.plus_until DESC LIMIT $2`, now, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PlusAccount{}
	for rows.Next() {
		var v PlusAccount
		if err := scanAccountView(rows, &v.AccountView, &v.PlusUntil); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (p *Postgres) AddGiftCode(ctx context.Context, code string, days int, at time.Time) error {
	tag, err := p.pool.Exec(ctx, `INSERT INTO plus_gift_codes (code, days, created_at) VALUES ($1, $2, $3)
		ON CONFLICT (code) DO NOTHING`, code, days, at)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrCodeExists
	}
	return nil
}

func (p *Postgres) UseGiftCode(ctx context.Context, code, acc string, at time.Time) (int, error) {
	var days int
	err := p.pool.QueryRow(ctx, `UPDATE plus_gift_codes SET used_by = $2, used_at = $3
		WHERE code = $1 AND used_at IS NULL RETURNING days`, code, acc, at).Scan(&days)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return days, err
}

func (p *Postgres) GiftCodes(ctx context.Context, limit int) ([]GiftCode, error) {
	rows, err := p.pool.Query(ctx, `SELECT g.code, g.days, g.created_at, COALESCE(a.phone, ''), g.used_at
		FROM plus_gift_codes g LEFT JOIN accounts a ON a.id = g.used_by
		ORDER BY g.created_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []GiftCode{}
	for rows.Next() {
		var v GiftCode
		if err := rows.Scan(&v.Code, &v.Days, &v.CreatedAt, &v.UsedBy, &v.UsedAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}
