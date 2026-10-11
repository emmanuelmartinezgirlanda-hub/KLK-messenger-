package store

import (
	"context"
	"sort"
	"time"
)

func (m *Memory) CreateTopup(_ context.Context, t Topup) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[t.AccountID]; !ok {
		return ErrNotFound
	}
	if m.topups == nil {
		m.topups = map[string]Topup{}
	}
	if t.CreatedAt.IsZero() {
		t.CreatedAt = time.Now()
	}
	t.UpdatedAt = t.CreatedAt
	m.topups[t.ID] = t
	return nil
}

func (m *Memory) GetTopup(_ context.Context, id string) (Topup, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.topups[id]
	if !ok {
		return Topup{}, ErrNotFound
	}
	return t, nil
}

func (m *Memory) TopupByPaymentRef(_ context.Context, ref string) (Topup, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, t := range m.topups {
		if ref != "" && t.PaymentRef == ref {
			return t, nil
		}
	}
	return Topup{}, ErrNotFound
}

func (m *Memory) MoveTopup(_ context.Context, id, from, to string, u TopupUpdate, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.topups[id]
	if !ok {
		return ErrNotFound
	}
	if t.Status != from {
		return ErrWrongState
	}
	t.Status = to
	if u.PaymentRef != "" {
		t.PaymentRef = u.PaymentRef
	}
	if u.PaymentIntent != "" {
		t.PaymentIntent = u.PaymentIntent
	}
	if u.ProviderRef != "" {
		t.ProviderRef = u.ProviderRef
	}
	if u.Error != "" {
		t.Error = u.Error
	}
	if u.CostCents != 0 {
		t.CostCents = u.CostCents
	}
	t.UpdatedAt = at
	m.topups[id] = t
	return nil
}

func (m *Memory) TopupsBy(_ context.Context, acc string, since time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, t := range m.topups {
		if t.AccountID == acc && !t.CreatedAt.Before(since) {
			n++
		}
	}
	return n, nil
}

func (m *Memory) sortedTopups(keep func(Topup) bool, limit int) []Topup {
	var out []Topup
	for _, t := range m.topups {
		if keep(t) {
			out = append(out, t)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

func (m *Memory) TopupsOf(_ context.Context, acc string, limit int) ([]Topup, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sortedTopups(func(t Topup) bool { return t.AccountID == acc }, limit), nil
}

func (m *Memory) StaleTopups(_ context.Context, status string, before time.Time, limit int) ([]Topup, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sortedTopups(func(t Topup) bool { return t.Status == status && t.UpdatedAt.Before(before) }, limit), nil
}

func (m *Memory) ListTopups(_ context.Context, limit int) ([]Topup, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sortedTopups(func(Topup) bool { return true }, limit), nil
}

func (m *Memory) TopupStats(_ context.Context, since time.Time) (TopupStats, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var s TopupStats
	for _, t := range m.topups {
		if t.CreatedAt.Before(since) {
			continue
		}
		switch {
		case t.Status == TopupDone && t.Test:
			s.TestDoneMonth++
		case t.Status == TopupDone:
			s.DoneMonth++
			s.IncomeMonth += t.PriceCents
			s.CostMonth += t.CostCents
		case (t.Status == TopupFailed || t.Status == TopupRefunded) && !t.Test:
			s.FailedMonth++
		}
	}
	return s, nil
}
