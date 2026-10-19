package store

import (
	"context"

	"github.com/google/uuid"
)

func (m *Memory) DeleteAccount(_ context.Context, acc string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.accounts[acc]
	if !ok {
		return ErrNotFound
	}
	delete(m.accounts, acc)
	delete(m.plus, acc)
	delete(m.byPhone, a.Phone)
	for k := range m.devices {
		if k.acc == acc {
			delete(m.devices, k)
			delete(m.signed, k)
			delete(m.prekeys, k)
			delete(m.push, k)
		}
	}
	for t, k := range m.byToken {
		if k.acc == acc {
			delete(m.byToken, t)
		}
	}
	for id, e := range m.envelopes {
		if e.ToAccount == acc {
			delete(m.envelopes, id)
		}
	}
	kept := m.reports[:0]
	for _, r := range m.reports {
		if r.Reporter != acc && r.Reported != acc {
			kept = append(kept, r)
		}
	}
	m.reports = kept
	if m.admin != nil {
		delete(m.admin.seen, acc)
	}
	delete(m.pin, a.Phone)
	delete(m.pin, acc)
	for _, members := range m.communities {
		delete(members, acc)
	}
	for id, t := range m.topups {
		if t.AccountID == acc {
			delete(m.topups, id)
		}
	}
	return nil
}

// En Postgres todo cuelga de accounts con ON DELETE CASCADE.
func (p *Postgres) DeleteAccount(ctx context.Context, acc string) error {
	if _, err := uuid.Parse(acc); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `DELETE FROM accounts WHERE id = $1`, acc)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
