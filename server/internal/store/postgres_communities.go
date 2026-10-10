package store

import (
	"context"

	"github.com/google/uuid"
)

func (p *Postgres) JoinCommunity(ctx context.Context, community, accountID string) error {
	if _, err := uuid.Parse(accountID); err != nil {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx,
		`INSERT INTO community_members (community, account_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		community, accountID)
	return err
}

func (p *Postgres) LeaveCommunity(ctx context.Context, community, accountID string) error {
	if _, err := uuid.Parse(accountID); err != nil {
		return nil
	}
	_, err := p.pool.Exec(ctx,
		`DELETE FROM community_members WHERE community = $1 AND account_id = $2`, community, accountID)
	return err
}

func (p *Postgres) CommunityCounts(ctx context.Context) (map[string]int, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT c.community, count(*)
		FROM community_members c JOIN accounts a ON a.id = c.account_id
		WHERE a.banned_at IS NULL
		GROUP BY c.community`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var c string
		var n int
		if err := rows.Scan(&c, &n); err != nil {
			return nil, err
		}
		out[c] = n
	}
	return out, rows.Err()
}

func (p *Postgres) CommunitiesOf(ctx context.Context, accountID string) ([]string, error) {
	out := []string{}
	if _, err := uuid.Parse(accountID); err != nil {
		return out, nil
	}
	rows, err := p.pool.Query(ctx,
		`SELECT community FROM community_members WHERE account_id = $1 ORDER BY community`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (p *Postgres) CommunityMembers(ctx context.Context, community string, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 1000
	}
	rows, err := p.pool.Query(ctx, `
		SELECT c.account_id::text
		FROM community_members c JOIN accounts a ON a.id = c.account_id
		WHERE c.community = $1 AND a.banned_at IS NULL
		ORDER BY c.joined_at
		LIMIT $2`, community, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
