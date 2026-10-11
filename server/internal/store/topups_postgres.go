package store

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const topupCols = `id, account_id, phone, operator_id, operator_name, local_amount::float8, local_currency,
	price_cents, cost_cents, currency, status, payment_ref, payment_intent, provider_ref, error, test, created_at, updated_at`

func scanTopup(row pgx.Row) (Topup, error) {
	var t Topup
	err := row.Scan(&t.ID, &t.AccountID, &t.Phone, &t.OperatorID, &t.OperatorName, &t.LocalAmount, &t.LocalCurrency,
		&t.PriceCents, &t.CostCents, &t.Currency, &t.Status, &t.PaymentRef, &t.PaymentIntent, &t.ProviderRef,
		&t.Error, &t.Test, &t.CreatedAt, &t.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Topup{}, ErrNotFound
	}
	return t, err
}

func (p *Postgres) CreateTopup(ctx context.Context, t Topup) error {
	if t.CreatedAt.IsZero() {
		t.CreatedAt = time.Now()
	}
	_, err := p.pool.Exec(ctx, `INSERT INTO topups (id, account_id, phone, operator_id, operator_name, local_amount,
		local_currency, price_cents, cost_cents, currency, status, test, created_at, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$13)`,
		t.ID, t.AccountID, t.Phone, t.OperatorID, t.OperatorName, t.LocalAmount, t.LocalCurrency,
		t.PriceCents, t.CostCents, t.Currency, t.Status, t.Test, t.CreatedAt)
	return err
}

func (p *Postgres) GetTopup(ctx context.Context, id string) (Topup, error) {
	if _, err := uuid.Parse(id); err != nil {
		return Topup{}, ErrNotFound
	}
	return scanTopup(p.pool.QueryRow(ctx, `SELECT `+topupCols+` FROM topups WHERE id = $1`, id))
}

func (p *Postgres) TopupByPaymentRef(ctx context.Context, ref string) (Topup, error) {
	if ref == "" {
		return Topup{}, ErrNotFound
	}
	return scanTopup(p.pool.QueryRow(ctx, `SELECT `+topupCols+` FROM topups WHERE payment_ref = $1`, ref))
}

func (p *Postgres) MoveTopup(ctx context.Context, id, from, to string, u TopupUpdate, at time.Time) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `UPDATE topups SET status = $3,
		payment_ref    = CASE WHEN $4 <> '' THEN $4 ELSE payment_ref END,
		payment_intent = CASE WHEN $5 <> '' THEN $5 ELSE payment_intent END,
		provider_ref   = CASE WHEN $6 <> '' THEN $6 ELSE provider_ref END,
		error          = CASE WHEN $7 <> '' THEN $7 ELSE error END,
		cost_cents     = CASE WHEN $8 <> 0 THEN $8 ELSE cost_cents END,
		updated_at = $9
		WHERE id = $1 AND status = $2`, id, from, to, u.PaymentRef, u.PaymentIntent, u.ProviderRef, u.Error, u.CostCents, at)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		if _, err := p.GetTopup(ctx, id); err != nil {
			return err
		}
		return ErrWrongState
	}
	return nil
}

func (p *Postgres) TopupsBy(ctx context.Context, acc string, since time.Time) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx, `SELECT count(*) FROM topups WHERE account_id = $1 AND created_at >= $2`, acc, since).Scan(&n)
	return n, err
}

func (p *Postgres) listTopups(ctx context.Context, q string, args ...any) ([]Topup, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+topupCols+` FROM topups `+q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Topup
	for rows.Next() {
		t, err := scanTopup(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (p *Postgres) TopupsOf(ctx context.Context, acc string, limit int) ([]Topup, error) {
	return p.listTopups(ctx, `WHERE account_id = $1 ORDER BY created_at DESC LIMIT $2`, acc, limit)
}

func (p *Postgres) StaleTopups(ctx context.Context, status string, before time.Time, limit int) ([]Topup, error) {
	return p.listTopups(ctx, `WHERE status = $1 AND updated_at < $2 ORDER BY created_at LIMIT $3`, status, before, limit)
}

func (p *Postgres) ListTopups(ctx context.Context, limit int) ([]Topup, error) {
	return p.listTopups(ctx, `ORDER BY created_at DESC LIMIT $1`, limit)
}

func (p *Postgres) TopupStats(ctx context.Context, since time.Time) (TopupStats, error) {
	var s TopupStats
	err := p.pool.QueryRow(ctx, `SELECT
		count(*) FILTER (WHERE status = 'done' AND NOT test),
		count(*) FILTER (WHERE status IN ('failed','refunded') AND NOT test),
		COALESCE(sum(price_cents) FILTER (WHERE status = 'done' AND NOT test), 0),
		COALESCE(sum(cost_cents)  FILTER (WHERE status = 'done' AND NOT test), 0),
		count(*) FILTER (WHERE status = 'done' AND test)
		FROM topups WHERE created_at >= $1`, since).
		Scan(&s.DoneMonth, &s.FailedMonth, &s.IncomeMonth, &s.CostMonth, &s.TestDoneMonth)
	return s, err
}
