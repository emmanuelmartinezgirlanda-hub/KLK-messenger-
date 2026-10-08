package store

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

type Postgres struct {
	pool *pgxpool.Pool
}

func NewPostgres(ctx context.Context, url string) (*Postgres, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("conectando a Postgres: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

func (p *Postgres) Close() { p.pool.Close() }

// Reset vacía todas las tablas. Solo para tests.
func (p *Postgres) Reset(ctx context.Context) error {
	_, err := p.pool.Exec(ctx, `TRUNCATE accounts, devices, signed_prekeys, one_time_prekeys, envelopes, attachments, reports CASCADE`)
	return err
}

// Migrate aplica los scripts SQL embebidos en orden.
func (p *Postgres) Migrate(ctx context.Context) error {
	names, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, n := range names {
		sql, err := migrations.ReadFile(n)
		if err != nil {
			return err
		}
		if _, err := p.pool.Exec(ctx, string(sql)); err != nil {
			return fmt.Errorf("migración %s: %w", n, err)
		}
	}
	return nil
}

func (p *Postgres) RegisterPrimary(ctx context.Context, r RegisterParams) (Device, error) {
	var d Device
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var accID string
		err := tx.QueryRow(ctx, `
			INSERT INTO accounts (id, phone) VALUES ($1, $2)
			ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
			RETURNING id`, uuid.NewString(), r.Phone).Scan(&accID)
		if err != nil {
			return err
		}
		// Borrar el dispositivo anterior elimina en cascada claves y cola.
		if _, err := tx.Exec(ctx,
			`DELETE FROM devices WHERE account_id = $1 AND device_id = 1`, accID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO devices (account_id, device_id, name, registration_id, identity_key, token_hash)
			VALUES ($1, 1, $2, $3, $4, $5)`,
			accID, r.DeviceName, r.RegistrationID, r.IdentityKey, r.TokenHash); err != nil {
			return err
		}
		d = Device{AccountID: accID, DeviceID: 1, Name: r.DeviceName,
			RegistrationID: r.RegistrationID, IdentityKey: r.IdentityKey}
		return nil
	})
	return d, err
}

func (p *Postgres) DeviceByTokenHash(ctx context.Context, h []byte) (Device, error) {
	var d Device
	err := p.pool.QueryRow(ctx, `
		SELECT account_id::text, device_id, name, registration_id, identity_key
		FROM devices WHERE token_hash = $1`, h).
		Scan(&d.AccountID, &d.DeviceID, &d.Name, &d.RegistrationID, &d.IdentityKey)
	return d, notFound(err)
}

func (p *Postgres) AccountIDByPhone(ctx context.Context, phone string) (string, error) {
	var id string
	err := p.pool.QueryRow(ctx, `SELECT id::text FROM accounts WHERE phone = $1`, phone).Scan(&id)
	return id, notFound(err)
}

func (p *Postgres) AccountIDsByPhones(ctx context.Context, phones []string) (map[string]string, error) {
	rows, err := p.pool.Query(ctx, `SELECT phone, id::text FROM accounts WHERE phone = ANY($1)`, phones)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var phone, id string
		if err := rows.Scan(&phone, &id); err != nil {
			return nil, err
		}
		out[phone] = id
	}
	return out, rows.Err()
}

func (p *Postgres) DeviceIDs(ctx context.Context, acc string) ([]int, error) {
	rows, err := p.pool.Query(ctx,
		`SELECT device_id FROM devices WHERE account_id = $1 ORDER BY device_id`, acc)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int])
}

func (p *Postgres) SetSignedPreKey(ctx context.Context, acc string, dev int, k SignedPreKey) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO signed_prekeys (account_id, device_id, key_id, public_key, signature)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (account_id, device_id) DO UPDATE
		SET key_id = EXCLUDED.key_id, public_key = EXCLUDED.public_key, signature = EXCLUDED.signature`,
		acc, dev, k.KeyID, k.PublicKey, k.Signature)
	return err
}

func (p *Postgres) AddPreKeys(ctx context.Context, acc string, dev int, keys []PreKey) error {
	batch := &pgx.Batch{}
	for _, k := range keys {
		batch.Queue(`
			INSERT INTO one_time_prekeys (account_id, device_id, key_id, public_key)
			VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING`, acc, dev, k.KeyID, k.PublicKey)
	}
	return p.pool.SendBatch(ctx, batch).Close()
}

func (p *Postgres) PreKeyCount(ctx context.Context, acc string, dev int) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx,
		`SELECT count(*) FROM one_time_prekeys WHERE account_id = $1 AND device_id = $2`, acc, dev).Scan(&n)
	return n, err
}

func (p *Postgres) TakeBundles(ctx context.Context, acc string) ([]Bundle, error) {
	var out []Bundle
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT d.device_id, d.registration_id, d.identity_key, s.key_id, s.public_key, s.signature
			FROM devices d JOIN signed_prekeys s USING (account_id, device_id)
			WHERE d.account_id = $1 ORDER BY d.device_id`, acc)
		if err != nil {
			return err
		}
		for rows.Next() {
			b := Bundle{SignedPreKey: &SignedPreKey{}}
			if err := rows.Scan(&b.DeviceID, &b.RegistrationID, &b.IdentityKey,
				&b.SignedPreKey.KeyID, &b.SignedPreKey.PublicKey, &b.SignedPreKey.Signature); err != nil {
				return err
			}
			out = append(out, b)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		for i := range out {
			// Consume atómicamente una prekey; SKIP LOCKED evita entregar la misma dos veces.
			var pk PreKey
			err := tx.QueryRow(ctx, `
				DELETE FROM one_time_prekeys WHERE ctid = (
					SELECT ctid FROM one_time_prekeys
					WHERE account_id = $1 AND device_id = $2
					ORDER BY key_id LIMIT 1 FOR UPDATE SKIP LOCKED)
				RETURNING key_id, public_key`, acc, out[i].DeviceID).Scan(&pk.KeyID, &pk.PublicKey)
			if errors.Is(err, pgx.ErrNoRows) {
				continue
			}
			if err != nil {
				return err
			}
			out[i].PreKey = &pk
		}
		return nil
	})
	if err == nil && len(out) == 0 {
		return nil, ErrNotFound
	}
	return out, err
}

func (p *Postgres) Enqueue(ctx context.Context, envs []Envelope) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		for _, e := range envs {
			if _, err := tx.Exec(ctx, `
				INSERT INTO envelopes (id, to_account, to_device, from_account, from_device,
				                       type, content, server_ts, deliver_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
				e.ID, e.ToAccount, e.ToDevice, e.FromAccount, e.FromDevice,
				e.Type, e.Content, e.ServerTS, e.DeliverAt); err != nil {
				return err
			}
		}
		return nil
	})
}

const envelopeCols = `id::text, to_account::text, to_device, from_account::text, from_device,
	type, content, server_ts, deliver_at`

func scanEnvelopes(rows pgx.Rows) ([]Envelope, error) {
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Envelope, error) {
		var e Envelope
		err := r.Scan(&e.ID, &e.ToAccount, &e.ToDevice, &e.FromAccount, &e.FromDevice,
			&e.Type, &e.Content, &e.ServerTS, &e.DeliverAt)
		return e, err
	})
}

func (p *Postgres) Pending(ctx context.Context, acc string, dev int, now time.Time, limit int) ([]Envelope, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+envelopeCols+` FROM envelopes
		WHERE to_account = $1 AND to_device = $2 AND deliver_at <= $3
		ORDER BY deliver_at LIMIT $4`, acc, dev, now, limit)
	if err != nil {
		return nil, err
	}
	return scanEnvelopes(rows)
}

func (p *Postgres) Ack(ctx context.Context, acc string, dev int, id string) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx,
		`DELETE FROM envelopes WHERE id = $1 AND to_account = $2 AND to_device = $3`, id, acc, dev)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (p *Postgres) DueScheduled(ctx context.Context, from, to time.Time) ([]Envelope, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+envelopeCols+` FROM envelopes
		WHERE deliver_at > server_ts AND deliver_at > $1 AND deliver_at <= $2`, from, to)
	if err != nil {
		return nil, err
	}
	return scanEnvelopes(rows)
}

func (p *Postgres) AddReport(ctx context.Context, r Report) error {
	msgs, err := json.Marshal(r.Messages)
	if err != nil {
		return err
	}
	if r.Messages == nil {
		msgs = []byte("[]")
	}
	_, err = p.pool.Exec(ctx,
		`INSERT INTO reports (id, reporter, reported, reason, messages) VALUES ($1, $2, $3, $4, $5)`,
		r.ID, r.Reporter, r.Reported, r.Reason, msgs)
	return err
}

func (p *Postgres) ReportsBy(ctx context.Context, reporter string, since time.Time) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx,
		`SELECT count(*) FROM reports WHERE reporter = $1 AND created_at > $2`, reporter, since).Scan(&n)
	return n, err
}

func (p *Postgres) AccountExists(ctx context.Context, id string) (bool, error) {
	if _, err := uuid.Parse(id); err != nil {
		return false, nil
	}
	var ok bool
	err := p.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, id).Scan(&ok)
	return ok, err
}

func (p *Postgres) PutAttachment(ctx context.Context, id, owner string, data []byte) error {
	_, err := p.pool.Exec(ctx,
		`INSERT INTO attachments (id, owner, data) VALUES ($1, $2, $3)`, id, owner, data)
	return err
}

func (p *Postgres) GetAttachment(ctx context.Context, id string) ([]byte, error) {
	if _, err := uuid.Parse(id); err != nil {
		return nil, ErrNotFound
	}
	var data []byte
	err := p.pool.QueryRow(ctx, `SELECT data FROM attachments WHERE id = $1`, id).Scan(&data)
	return data, notFound(err)
}

func (p *Postgres) PurgeAttachments(ctx context.Context, before time.Time) (int, error) {
	tag, err := p.pool.Exec(ctx, `DELETE FROM attachments WHERE created_at < $1`, before)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}
