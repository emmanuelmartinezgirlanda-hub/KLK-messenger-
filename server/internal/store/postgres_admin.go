package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (p *Postgres) Touch(ctx context.Context, acc string, at time.Time) error {
	_, err := p.pool.Exec(ctx, `UPDATE accounts SET last_seen = $2 WHERE id = $1`, acc, at)
	return err
}

func (p *Postgres) PhoneBanned(ctx context.Context, phone string) (bool, error) {
	var b bool
	err := p.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM accounts WHERE phone = $1 AND banned_at IS NOT NULL)`, phone).Scan(&b)
	return b, err
}

func (p *Postgres) SetBanned(ctx context.Context, acc string, banned bool, reason string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	var tag interface{ RowsAffected() int64 }
	var err error
	if banned {
		tag, err = p.pool.Exec(ctx, `UPDATE accounts SET banned_at = now(), banned_reason = $2 WHERE id = $1`, acc, reason)
	} else {
		tag, err = p.pool.Exec(ctx, `UPDATE accounts SET banned_at = NULL, banned_reason = '' WHERE id = $1`, acc)
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (p *Postgres) ResolveReport(ctx context.Context, id string) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `UPDATE reports SET resolved_at = now() WHERE id = $1 AND resolved_at IS NULL`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

const accountViewCols = `a.id::text, a.phone, a.created_at, a.last_seen, a.banned_at, a.banned_reason,
	(SELECT count(*) FROM reports x WHERE x.reported = a.id)`

func scanAccountView(row pgx.Row, v *AccountView, extra ...any) error {
	dest := append([]any{&v.ID, &v.Phone, &v.CreatedAt, &v.LastSeen, &v.BannedAt, &v.BannedReason, &v.Reports}, extra...)
	return row.Scan(dest...)
}

func (p *Postgres) ListReports(ctx context.Context, open bool, limit int) ([]ReportView, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT r.id::text, r.reason, r.messages, r.created_at, r.resolved_at, rp.phone, `+accountViewCols+`
		FROM reports r
		JOIN accounts a ON a.id = r.reported
		JOIN accounts rp ON rp.id = r.reporter
		WHERE NOT $1 OR r.resolved_at IS NULL
		ORDER BY r.created_at DESC LIMIT $2`, open, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReportView{}
	for rows.Next() {
		var v ReportView
		var msgs []byte
		if err := rows.Scan(&v.ID, &v.Reason, &msgs, &v.CreatedAt, &v.ResolvedAt, &v.Reporter,
			&v.Reported.ID, &v.Reported.Phone, &v.Reported.CreatedAt, &v.Reported.LastSeen,
			&v.Reported.BannedAt, &v.Reported.BannedReason, &v.Reported.Reports); err != nil {
			return nil, err
		}
		v.Reporter = MaskPhone(v.Reporter)
		v.Messages = []string{}
		_ = json.Unmarshal(msgs, &v.Messages)
		out = append(out, v)
	}
	return out, rows.Err()
}

func (p *Postgres) BannedAccounts(ctx context.Context, limit int) ([]AccountView, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+accountViewCols+` FROM accounts a
		WHERE a.banned_at IS NOT NULL ORDER BY a.banned_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AccountView{}
	for rows.Next() {
		var v AccountView
		if err := scanAccountView(rows, &v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (p *Postgres) LogSMS(ctx context.Context, country string, at time.Time) error {
	_, err := p.pool.Exec(ctx, `INSERT INTO sms_events (sent_at, country) VALUES ($1, $2)`, at, country)
	return err
}

func (p *Postgres) Stats(ctx context.Context, now time.Time) (Stats, error) {
	s := Stats{Countries: map[string]int{}}
	today := now.UTC().Truncate(24 * time.Hour)
	month := time.Date(now.UTC().Year(), now.UTC().Month(), 1, 0, 0, 0, 0, time.UTC)
	err := p.pool.QueryRow(ctx, `
		SELECT count(*),
		       count(*) FILTER (WHERE created_at >= $2),
		       count(*) FILTER (WHERE created_at > $1::timestamptz - interval '7 days'),
		       count(*) FILTER (WHERE last_seen > $1::timestamptz - interval '1 day'),
		       count(*) FILTER (WHERE last_seen > $1::timestamptz - interval '7 days'),
		       count(*) FILTER (WHERE last_seen > $1::timestamptz - interval '30 days'),
		       count(*) FILTER (WHERE banned_at IS NOT NULL)
		FROM accounts`, now, today).
		Scan(&s.Users, &s.NewToday, &s.New7d, &s.Active24h, &s.Active7d, &s.Active30d, &s.Banned)
	if err != nil {
		return s, err
	}
	if err := p.pool.QueryRow(ctx, `SELECT count(*) FROM reports WHERE resolved_at IS NULL`).Scan(&s.OpenReports); err != nil {
		return s, err
	}
	if err := p.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE sent_at >= $2),
		       count(*) FILTER (WHERE sent_at >= $3),
		       count(*) FILTER (WHERE sent_at > $1::timestamptz - interval '30 days')
		FROM sms_events WHERE sent_at > $1::timestamptz - interval '40 days'`, now, today, month).
		Scan(&s.SMSToday, &s.SMSMonth, &s.SMS30d); err != nil {
		return s, err
	}
	if err := p.pool.QueryRow(ctx, `SELECT count(*), coalesce(sum(length(data)), 0) FROM attachments`).
		Scan(&s.Attachments, &s.AttachBytes); err != nil {
		return s, err
	}
	var idx map[string]int
	s.Signups, idx = days30(now)
	s.SMSDaily, _ = days30(now)
	from := now.UTC().Truncate(24*time.Hour).AddDate(0, 0, -29)
	fill := func(q string, into []DayCount) error {
		rows, err := p.pool.Query(ctx, q, from)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var day time.Time
			var n int
			if err := rows.Scan(&day, &n); err != nil {
				return err
			}
			if i, ok := idx[day.Format("2006-01-02")]; ok {
				into[i].Count = n
			}
		}
		return rows.Err()
	}
	if err := fill(`SELECT (created_at AT TIME ZONE 'UTC')::date, count(*) FROM accounts
		WHERE created_at >= $1 GROUP BY 1`, s.Signups); err != nil {
		return s, err
	}
	if err := fill(`SELECT (sent_at AT TIME ZONE 'UTC')::date, count(*) FROM sms_events
		WHERE sent_at >= $1 GROUP BY 1`, s.SMSDaily); err != nil {
		return s, err
	}
	rows, err := p.pool.Query(ctx, `SELECT phone FROM accounts`)
	if err != nil {
		return s, err
	}
	defer rows.Close()
	for rows.Next() {
		var ph string
		if err := rows.Scan(&ph); err != nil {
			return s, err
		}
		s.Countries[CountryOf(ph)]++
	}
	return s, rows.Err()
}

func (p *Postgres) AddAnnouncement(ctx context.Context, a Announcement) error {
	_, err := p.pool.Exec(ctx, `INSERT INTO announcements (id, title, body, created_at) VALUES ($1, $2, $3, $4)`,
		a.ID, a.Title, a.Body, a.CreatedAt)
	return err
}

func (p *Postgres) DeleteAnnouncement(ctx context.Context, id string) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `DELETE FROM announcements WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (p *Postgres) Announcements(ctx context.Context, limit int) ([]Announcement, error) {
	rows, err := p.pool.Query(ctx, `SELECT id::text, title, body, created_at FROM announcements
		ORDER BY created_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Announcement, error) {
		var a Announcement
		err := r.Scan(&a.ID, &a.Title, &a.Body, &a.CreatedAt)
		return a, err
	})
}
