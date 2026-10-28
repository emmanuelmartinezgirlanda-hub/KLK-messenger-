package store

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ErrTaken: ese @usuario o ese correo ya los tiene otra cuenta.
var ErrTaken = errors.New("ya está en uso")

// IdentityStore: el @usuario y el correo de cada cuenta.
type IdentityStore interface {
	// SetUsername pone (o quita, con "") el @usuario. ErrTaken si es de otro.
	SetUsername(ctx context.Context, account, username string) error
	Username(ctx context.Context, account string) (string, error)
	// AccountByUsername devuelve ErrNotFound si no existe o la cuenta está bloqueada.
	AccountByUsername(ctx context.Context, username string) (string, error)
	// SetEmail pone (o quita, con "") el correo verificado. ErrTaken si es de otro.
	SetEmail(ctx context.Context, account, email string) error
	Email(ctx context.Context, account string) (string, error)
	// AccountByEmail devuelve la cuenta con ese correo y con qué se registró
	// (su número, o "mail:…" si se creó con correo).
	AccountByEmail(ctx context.Context, email string) (id, identity string, err error)
}

// ---------- Memoria ----------

type memIdentity struct {
	usernames map[string]string // usuario -> cuenta
	userOf    map[string]string // cuenta -> usuario
	emails    map[string]string // correo -> cuenta
	emailOf   map[string]string // cuenta -> correo
}

func (m *Memory) ident() *memIdentity {
	if m.idents == nil {
		m.idents = &memIdentity{usernames: map[string]string{}, userOf: map[string]string{},
			emails: map[string]string{}, emailOf: map[string]string{}}
	}
	return m.idents
}

func (m *Memory) SetUsername(_ context.Context, acc, u string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	id := m.ident()
	if u != "" {
		if other, ok := id.usernames[u]; ok && other != acc {
			return ErrTaken
		}
	}
	if old, ok := id.userOf[acc]; ok {
		delete(id.usernames, old)
		delete(id.userOf, acc)
	}
	if u != "" {
		id.usernames[u] = acc
		id.userOf[acc] = u
	}
	return nil
}

func (m *Memory) Username(_ context.Context, acc string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.ident().userOf[acc], nil
}

func (m *Memory) AccountByUsername(_ context.Context, u string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	acc, ok := m.ident().usernames[u]
	if !ok || m.bannedLocked(acc) {
		return "", ErrNotFound
	}
	return acc, nil
}

func (m *Memory) SetEmail(_ context.Context, acc, e string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	id := m.ident()
	if e != "" {
		if other, ok := id.emails[e]; ok && other != acc {
			return ErrTaken
		}
	}
	if old, ok := id.emailOf[acc]; ok {
		delete(id.emails, old)
		delete(id.emailOf, acc)
	}
	if e != "" {
		id.emails[e] = acc
		id.emailOf[acc] = e
	}
	return nil
}

func (m *Memory) Email(_ context.Context, acc string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.ident().emailOf[acc], nil
}

func (m *Memory) AccountByEmail(_ context.Context, e string) (string, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	acc, ok := m.ident().emails[e]
	if !ok {
		return "", "", ErrNotFound
	}
	a, ok := m.accounts[acc]
	if !ok {
		return "", "", ErrNotFound
	}
	return acc, a.Phone, nil
}

func (m *Memory) deleteIdentityLocked(acc string) {
	if m.idents == nil {
		return
	}
	id := m.idents
	if u, ok := id.userOf[acc]; ok {
		delete(id.usernames, u)
		delete(id.userOf, acc)
	}
	if e, ok := id.emailOf[acc]; ok {
		delete(id.emails, e)
		delete(id.emailOf, acc)
	}
}

// ---------- Postgres ----------

func uniqueViolation(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && pg.Code == "23505"
}

func (p *Postgres) SetUsername(ctx context.Context, acc, u string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	var val any
	if u != "" {
		val = u
	}
	tag, err := p.pool.Exec(ctx, `UPDATE accounts SET username = $2 WHERE id = $1`, acc, val)
	if uniqueViolation(err) {
		return ErrTaken
	}
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) Username(ctx context.Context, acc string) (string, error) {
	if _, err := uuid.Parse(acc); err != nil {
		return "", nil
	}
	var u *string
	err := p.pool.QueryRow(ctx, `SELECT username FROM accounts WHERE id = $1`, acc).Scan(&u)
	if errors.Is(err, pgx.ErrNoRows) || u == nil {
		return "", nil
	}
	return *u, err
}

func (p *Postgres) AccountByUsername(ctx context.Context, u string) (string, error) {
	var id string
	err := p.pool.QueryRow(ctx, `SELECT id::text FROM accounts WHERE username = $1 AND banned_at IS NULL`, u).Scan(&id)
	return id, notFound(err)
}

func (p *Postgres) SetEmail(ctx context.Context, acc, e string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	if e == "" {
		_, err := p.pool.Exec(ctx, `DELETE FROM account_emails WHERE account_id = $1`, acc)
		return err
	}
	_, err := p.pool.Exec(ctx, `
		INSERT INTO account_emails (account_id, email, verified_at) VALUES ($1, $2, now())
		ON CONFLICT (account_id) DO UPDATE SET email = EXCLUDED.email, verified_at = now()`, acc, e)
	if uniqueViolation(err) {
		return ErrTaken
	}
	if err != nil && strings.Contains(err.Error(), "foreign key") {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) Email(ctx context.Context, acc string) (string, error) {
	if _, err := uuid.Parse(acc); err != nil {
		return "", nil
	}
	var e string
	err := p.pool.QueryRow(ctx, `SELECT email FROM account_emails WHERE account_id = $1`, acc).Scan(&e)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return e, err
}

func (p *Postgres) AccountByEmail(ctx context.Context, e string) (string, string, error) {
	var id, phone string
	err := p.pool.QueryRow(ctx, `
		SELECT a.id::text, a.phone FROM account_emails e JOIN accounts a ON a.id = e.account_id
		WHERE e.email = $1`, e).Scan(&id, &phone)
	return id, phone, notFound(err)
}
