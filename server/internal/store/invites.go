package store

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Errores al canjear una invitación.
var (
	ErrSelfInvite     = errors.New("no puedes usar tu propio código")
	ErrAlreadyInvited = errors.New("ya usaste un código de invitación")
	ErrTooLate        = errors.New("el código solo vale al empezar en KLK")
)

// InviteStore: «Invita a tus amigos y gana Plus».
type InviteStore interface {
	// InviteCode devuelve el código de la cuenta (lo crea la primera vez).
	InviteCode(ctx context.Context, accountID string) (string, error)
	// InviteCount: cuántas personas se unieron con el código de la cuenta.
	InviteCount(ctx context.Context, accountID string) (int, error)
	// InviteOwner: de quién es un código (ErrNotFound si no existe).
	InviteOwner(ctx context.Context, code string) (string, error)
	// InvitedBy: quién invitó a la cuenta ("" si nadie).
	InvitedBy(ctx context.Context, accountID string) (string, error)
	// ClaimInvite apunta que [invitee] llegó con [code]. Solo vale si la
	// cuenta tiene menos de [maxAge]. Devuelve quién invitó y cuántos lleva.
	ClaimInvite(ctx context.Context, code, invitee string, at time.Time, maxAge time.Duration) (inviter string, count int, err error)
}

// Sin 0/O ni 1/I/L para que no se confundan al dictarlo.
const inviteAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func newInviteCode() string {
	b := make([]byte, 6)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(inviteAlphabet))))
		b[i] = inviteAlphabet[n.Int64()]
	}
	return "KLK" + string(b)
}

// ---------- Memoria ----------

type memInvites struct {
	codes   map[string]string // cuenta -> código
	byCode  map[string]string // código -> cuenta
	invitee map[string]string // invitado -> quien invitó
}

func (m *Memory) inv() *memInvites {
	if m.invites == nil {
		m.invites = &memInvites{codes: map[string]string{}, byCode: map[string]string{}, invitee: map[string]string{}}
	}
	return m.invites
}

func (m *Memory) InviteCode(_ context.Context, acc string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return "", ErrNotFound
	}
	iv := m.inv()
	if c, ok := iv.codes[acc]; ok {
		return c, nil
	}
	for {
		c := newInviteCode()
		if _, taken := iv.byCode[c]; !taken {
			iv.codes[acc], iv.byCode[c] = c, acc
			return c, nil
		}
	}
}

func (m *Memory) InviteCount(_ context.Context, acc string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for invitee, by := range m.inv().invitee {
		if _, alive := m.accounts[invitee]; alive && by == acc {
			n++
		}
	}
	return n, nil
}

func (m *Memory) InviteOwner(_ context.Context, code string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	acc, ok := m.inv().byCode[code]
	if _, alive := m.accounts[acc]; !ok || !alive {
		return "", ErrNotFound
	}
	return acc, nil
}

func (m *Memory) InvitedBy(_ context.Context, acc string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.inv().invitee[acc], nil
}

func (m *Memory) ClaimInvite(_ context.Context, code, invitee string, at time.Time, maxAge time.Duration) (string, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	iv := m.inv()
	a, ok := m.accounts[invitee]
	if !ok {
		return "", 0, ErrNotFound
	}
	inviter, ok := iv.byCode[code]
	if _, alive := m.accounts[inviter]; !ok || !alive {
		return "", 0, ErrNotFound
	}
	if inviter == invitee {
		return "", 0, ErrSelfInvite
	}
	if _, done := iv.invitee[invitee]; done {
		return "", 0, ErrAlreadyInvited
	}
	if at.Sub(a.CreatedAt) > maxAge {
		return "", 0, ErrTooLate
	}
	iv.invitee[invitee] = inviter
	n := 0
	for i, by := range iv.invitee {
		if _, alive := m.accounts[i]; alive && by == inviter {
			n++
		}
	}
	return inviter, n, nil
}

// ---------- Postgres ----------

func (p *Postgres) InviteCode(ctx context.Context, acc string) (string, error) {
	var c string
	err := p.pool.QueryRow(ctx, `SELECT code FROM invite_codes WHERE account_id = $1`, acc).Scan(&c)
	if err == nil {
		return c, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}
	for i := 0; i < 8; i++ {
		c = newInviteCode()
		err = p.pool.QueryRow(ctx, `INSERT INTO invite_codes (account_id, code) VALUES ($1, $2)
			ON CONFLICT (account_id) DO UPDATE SET code = invite_codes.code RETURNING code`, acc, c).Scan(&c)
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // código repetido: otro intento
			continue
		}
		if errors.As(err, &pgErr) && pgErr.Code == "23503" {
			return "", ErrNotFound
		}
		return c, err
	}
	return "", errors.New("no se pudo crear el código")
}

func (p *Postgres) InviteCount(ctx context.Context, acc string) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx, `SELECT count(*) FROM invites WHERE inviter_id = $1`, acc).Scan(&n)
	return n, err
}

func (p *Postgres) InviteOwner(ctx context.Context, code string) (string, error) {
	var acc string
	err := p.pool.QueryRow(ctx, `SELECT account_id::text FROM invite_codes WHERE code = $1`, code).Scan(&acc)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return acc, err
}

func (p *Postgres) InvitedBy(ctx context.Context, acc string) (string, error) {
	var by string
	err := p.pool.QueryRow(ctx, `SELECT inviter_id::text FROM invites WHERE invitee_id = $1`, acc).Scan(&by)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return by, err
}

func (p *Postgres) ClaimInvite(ctx context.Context, code, invitee string, at time.Time, maxAge time.Duration) (string, int, error) {
	var inviter string
	err := p.pool.QueryRow(ctx, `SELECT account_id::text FROM invite_codes WHERE code = $1`, code).Scan(&inviter)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	if err != nil {
		return "", 0, err
	}
	if inviter == invitee {
		return "", 0, ErrSelfInvite
	}
	var created time.Time
	err = p.pool.QueryRow(ctx, `SELECT created_at FROM accounts WHERE id = $1`, invitee).Scan(&created)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	if err != nil {
		return "", 0, err
	}
	if at.Sub(created) > maxAge {
		return "", 0, ErrTooLate
	}
	tag, err := p.pool.Exec(ctx, `INSERT INTO invites (invitee_id, inviter_id, created_at) VALUES ($1, $2, $3)
		ON CONFLICT (invitee_id) DO NOTHING`, invitee, inviter, at)
	if err != nil {
		return "", 0, err
	}
	if tag.RowsAffected() == 0 {
		return "", 0, ErrAlreadyInvited
	}
	n, err := p.InviteCount(ctx, inviter)
	return inviter, n, err
}
