package store

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Memory es una implementación en memoria para desarrollo y tests.
type Memory struct {
	mu        sync.Mutex
	accounts  map[string]Account // por ID
	byPhone   map[string]string  // phone -> accountID
	devices   map[devKey]Device
	byToken   map[string]devKey
	signed    map[devKey]SignedPreKey
	prekeys   map[devKey][]PreKey
	envelopes map[string]Envelope
	attach    map[string]memAttachment
	reports   []Report
	admin     *memAdmin
}

type memAttachment struct {
	data    []byte
	created time.Time
}

func (m *Memory) AddReport(_ context.Context, r Report) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[r.Reporter]; !ok {
		return ErrNotFound
	}
	if _, ok := m.accounts[r.Reported]; !ok {
		return ErrNotFound
	}
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now()
	}
	m.reports = append(m.reports, r)
	return nil
}

func (m *Memory) ReportsBy(_ context.Context, reporter string, since time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, r := range m.reports {
		if r.Reporter == reporter && r.CreatedAt.After(since) {
			n++
		}
	}
	return n, nil
}

func (m *Memory) AccountExists(_ context.Context, id string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.accounts[id]
	return ok, nil
}

// Reports devuelve las denuncias guardadas (para pruebas).
func (m *Memory) Reports() []Report {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Report(nil), m.reports...)
}

func (m *Memory) PutAttachment(_ context.Context, id, owner string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[owner]; !ok {
		return ErrNotFound
	}
	m.attach[id] = memAttachment{data: append([]byte(nil), data...), created: time.Now()}
	return nil
}

func (m *Memory) GetAttachment(_ context.Context, id string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.attach[id]
	if !ok {
		return nil, ErrNotFound
	}
	return a.data, nil
}

func (m *Memory) PurgeAttachments(_ context.Context, before time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for id, a := range m.attach {
		if a.created.Before(before) {
			delete(m.attach, id)
			n++
		}
	}
	return n, nil
}

type devKey struct {
	acc string
	dev int
}

func NewMemory() *Memory {
	return &Memory{
		accounts:  map[string]Account{},
		byPhone:   map[string]string{},
		devices:   map[devKey]Device{},
		byToken:   map[string]devKey{},
		signed:    map[devKey]SignedPreKey{},
		prekeys:   map[devKey][]PreKey{},
		envelopes: map[string]Envelope{},
		attach:    map[string]memAttachment{},
	}
}

func (m *Memory) RegisterPrimary(_ context.Context, p RegisterParams) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	accID, ok := m.byPhone[p.Phone]
	if !ok {
		accID = uuid.NewString()
		m.accounts[accID] = Account{ID: accID, Phone: p.Phone, CreatedAt: time.Now()}
		m.byPhone[p.Phone] = accID
	}
	k := devKey{accID, 1}
	// Sustituye el dispositivo anterior: sus tokens, claves y cola dejan de valer.
	for t, dk := range m.byToken {
		if dk == k {
			delete(m.byToken, t)
		}
	}
	delete(m.signed, k)
	delete(m.prekeys, k)
	for id, e := range m.envelopes {
		if e.ToAccount == accID && e.ToDevice == 1 {
			delete(m.envelopes, id)
		}
	}
	d := Device{AccountID: accID, DeviceID: 1, Name: p.DeviceName,
		RegistrationID: p.RegistrationID, IdentityKey: p.IdentityKey}
	m.devices[k] = d
	m.byToken[string(p.TokenHash)] = k
	return d, nil
}

func (m *Memory) DeviceByTokenHash(_ context.Context, h []byte) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k, ok := m.byToken[string(h)]
	if !ok {
		return Device{}, ErrNotFound
	}
	d := m.devices[k]
	_, d.Banned = m.adm().banned[k.acc]
	return d, nil
}

func (m *Memory) AccountIDByPhone(_ context.Context, phone string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.byPhone[phone]
	if !ok {
		return "", ErrNotFound
	}
	return id, nil
}

func (m *Memory) AccountIDsByPhones(_ context.Context, phones []string) (map[string]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := map[string]string{}
	for _, p := range phones {
		if id, ok := m.byPhone[p]; ok {
			out[p] = id
		}
	}
	return out, nil
}

func (m *Memory) DeviceIDs(_ context.Context, acc string) ([]int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.deviceIDsLocked(acc), nil
}

func (m *Memory) deviceIDsLocked(acc string) []int {
	var ids []int
	for k := range m.devices {
		if k.acc == acc {
			ids = append(ids, k.dev)
		}
	}
	sort.Ints(ids)
	return ids
}

func (m *Memory) SetSignedPreKey(_ context.Context, acc string, dev int, k SignedPreKey) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.devices[devKey{acc, dev}]; !ok {
		return ErrNotFound
	}
	m.signed[devKey{acc, dev}] = k
	return nil
}

func (m *Memory) AddPreKeys(_ context.Context, acc string, dev int, keys []PreKey) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	dk := devKey{acc, dev}
	if _, ok := m.devices[dk]; !ok {
		return ErrNotFound
	}
	existing := map[int]bool{}
	for _, k := range m.prekeys[dk] {
		existing[k.KeyID] = true
	}
	for _, k := range keys {
		if !existing[k.KeyID] {
			m.prekeys[dk] = append(m.prekeys[dk], k)
			existing[k.KeyID] = true
		}
	}
	return nil
}

func (m *Memory) PreKeyCount(_ context.Context, acc string, dev int) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.prekeys[devKey{acc, dev}]), nil
}

func (m *Memory) TakeBundles(_ context.Context, acc string) ([]Bundle, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := m.deviceIDsLocked(acc)
	if len(ids) == 0 {
		return nil, ErrNotFound
	}
	var out []Bundle
	for _, id := range ids {
		dk := devKey{acc, id}
		d := m.devices[dk]
		spk, ok := m.signed[dk]
		if !ok {
			continue // dispositivo sin claves publicadas todavía
		}
		b := Bundle{DeviceID: id, RegistrationID: d.RegistrationID, IdentityKey: d.IdentityKey, SignedPreKey: &spk}
		if pks := m.prekeys[dk]; len(pks) > 0 {
			pk := pks[0]
			m.prekeys[dk] = pks[1:]
			b.PreKey = &pk
		}
		out = append(out, b)
	}
	return out, nil
}

func (m *Memory) Enqueue(_ context.Context, envs []Envelope) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, e := range envs {
		if _, ok := m.devices[devKey{e.ToAccount, e.ToDevice}]; !ok {
			return ErrNotFound
		}
	}
	for _, e := range envs {
		m.envelopes[e.ID] = e
	}
	return nil
}

func (m *Memory) Pending(_ context.Context, acc string, dev int, now time.Time, limit int) ([]Envelope, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Envelope
	for _, e := range m.envelopes {
		if e.ToAccount == acc && e.ToDevice == dev && !e.DeliverAt.After(now) {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DeliverAt.Before(out[j].DeliverAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) Ack(_ context.Context, acc string, dev int, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.envelopes[id]
	if !ok || e.ToAccount != acc || e.ToDevice != dev {
		return ErrNotFound
	}
	delete(m.envelopes, id)
	return nil
}

func (m *Memory) DueScheduled(_ context.Context, from, to time.Time) ([]Envelope, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Envelope
	for _, e := range m.envelopes {
		if e.DeliverAt.After(e.ServerTS) && e.DeliverAt.After(from) && !e.DeliverAt.After(to) {
			out = append(out, e)
		}
	}
	return out, nil
}
