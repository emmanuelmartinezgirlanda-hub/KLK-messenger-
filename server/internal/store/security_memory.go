package store

import (
	"context"
	"time"
)

type memPin struct {
	hash, salt []byte
	failures   int
}

func (m *Memory) pins() map[string]*memPin {
	if m.pin == nil {
		m.pin = map[string]*memPin{}
	}
	return m.pin
}

func (m *Memory) PinState(_ context.Context, phone string) (PinState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.byPhone[phone]
	if !ok {
		return PinState{}, nil
	}
	st := PinState{Exists: true}
	if p := m.pins()[id]; p != nil {
		st.Hash, st.Salt, st.Failures = p.hash, p.salt, p.failures
	}
	if t, ok := m.adm().seen[id]; ok {
		st.LastSeen = &t
	}
	return st, nil
}

func (m *Memory) SetPin(_ context.Context, acc string, hash, salt []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	if hash == nil {
		delete(m.pins(), acc)
		return nil
	}
	m.pins()[acc] = &memPin{hash: hash, salt: salt}
	return nil
}

func (m *Memory) PinFailed(_ context.Context, phone string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p := m.pins()[m.byPhone[phone]]
	if p == nil {
		return 0, nil
	}
	p.failures++
	return p.failures, nil
}

func (m *Memory) PinOK(_ context.Context, phone string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p := m.pins()[m.byPhone[phone]]; p != nil {
		p.failures = 0
	}
	return nil
}

func (m *Memory) SMSCount(_ context.Context, country string, since time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, e := range m.adm().sms {
		if !e.at.Before(since) && (country == "" || e.country == country) {
			n++
		}
	}
	return n, nil
}

func (m *Memory) AccountPhone(_ context.Context, acc string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.accounts[acc]
	if !ok {
		return "", ErrNotFound
	}
	return a.Phone, nil
}
