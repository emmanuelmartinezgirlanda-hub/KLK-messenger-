package store

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (p *Postgres) PinState(ctx context.Context, phone string) (PinState, error) {
	var st PinState
	err := p.pool.QueryRow(ctx,
		`SELECT pin_hash, pin_salt, pin_failures, last_seen FROM accounts WHERE phone = $1`, phone).
		Scan(&st.Hash, &st.Salt, &st.Failures, &st.LastSeen)
	if errors.Is(err, pgx.ErrNoRows) {
		return PinState{}, nil
	}
	if err != nil {
		return PinState{}, err
	}
	st.Exists = true
	return st, nil
}

func (p *Postgres) SetPin(ctx context.Context, acc string, hash, salt []byte) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx,
		`UPDATE accounts SET pin_hash = $2, pin_salt = $3, pin_failures = 0 WHERE id = $1`, acc, hash, salt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (p *Postgres) PinFailed(ctx context.Context, phone string) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx,
		`UPDATE accounts SET pin_failures = pin_failures + 1 WHERE phone = $1 RETURNING pin_failures`, phone).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return n, err
}

func (p *Postgres) PinOK(ctx context.Context, phone string) error {
	_, err := p.pool.Exec(ctx, `UPDATE accounts SET pin_failures = 0 WHERE phone = $1`, phone)
	return err
}

func (p *Postgres) SMSCount(ctx context.Context, country string, since time.Time) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx,
		`SELECT count(*) FROM sms_events WHERE sent_at >= $1 AND ($2 = '' OR country = $2)`, since, country).Scan(&n)
	return n, err
}

func (p *Postgres) AccountPhone(ctx context.Context, acc string) (string, error) {
	if _, err := uuid.Parse(acc); err != nil {
		return "", ErrNotFound
	}
	var phone string
	err := p.pool.QueryRow(ctx, `SELECT phone FROM accounts WHERE id = $1`, acc).Scan(&phone)
	return phone, notFound(err)
}
