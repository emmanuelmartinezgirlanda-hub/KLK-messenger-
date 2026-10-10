package store

import (
	"context"
	"sort"

	"time"
)

// Datos del panel del dueño en el almacén en memoria.
type memAdmin struct {
	seen     map[string]time.Time
	banned   map[string]memBan
	resolved map[string]time.Time
	news     []Announcement
	sms      []memSMS
}

type memBan struct {
	at     time.Time
	reason string
}

type memSMS struct {
	at      time.Time
	country string
}

func (m *Memory) adm() *memAdmin {
	if m.admin == nil {
		m.admin = &memAdmin{seen: map[string]time.Time{}, banned: map[string]memBan{}, resolved: map[string]time.Time{}}
	}
	return m.admin
}

func (m *Memory) Touch(_ context.Context, acc string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.adm().seen[acc] = at
	return nil
}

func (m *Memory) PhoneBanned(_ context.Context, phone string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.byPhone[phone]
	if !ok {
		return false, nil
	}
	_, b := m.adm().banned[id]
	return b, nil
}

func (m *Memory) SetBanned(_ context.Context, acc string, banned bool, reason string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	if banned {
		m.adm().banned[acc] = memBan{at: time.Now(), reason: reason}
	} else {
		delete(m.adm().banned, acc)
	}
	return nil
}

func (m *Memory) ResolveReport(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, r := range m.reports {
		if r.ID == id {
			m.adm().resolved[id] = time.Now()
			return nil
		}
	}
	return ErrNotFound
}

func (m *Memory) accountViewLocked(id string) AccountView {
	a := m.accounts[id]
	v := AccountView{ID: id, Phone: a.Phone, CreatedAt: a.CreatedAt}
	if t, ok := m.adm().seen[id]; ok {
		v.LastSeen = &t
	}
	if b, ok := m.adm().banned[id]; ok {
		t := b.at
		v.BannedAt, v.BannedReason = &t, b.reason
	}
	for _, r := range m.reports {
		if r.Reported == id {
			v.Reports++
		}
	}
	return v
}

func (m *Memory) ListReports(_ context.Context, open bool, limit int) ([]ReportView, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []ReportView{}
	for i := len(m.reports) - 1; i >= 0 && len(out) < limit; i-- {
		r := m.reports[i]
		res, isRes := m.adm().resolved[r.ID]
		if open && isRes {
			continue
		}
		v := ReportView{ID: r.ID, Reason: r.Reason, Messages: append([]string{}, r.Messages...), CreatedAt: r.CreatedAt,
			Reporter: MaskPhone(m.accounts[r.Reporter].Phone), Reported: m.accountViewLocked(r.Reported)}
		if isRes {
			t := res
			v.ResolvedAt = &t
		}
		out = append(out, v)
	}
	return out, nil
}

func (m *Memory) BannedAccounts(_ context.Context, limit int) ([]AccountView, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []AccountView{}
	for id := range m.adm().banned {
		out = append(out, m.accountViewLocked(id))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BannedAt.After(*out[j].BannedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) LogSMS(_ context.Context, country string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.adm().sms = append(m.adm().sms, memSMS{at: at, country: country})
	return nil
}

func (m *Memory) Stats(_ context.Context, now time.Time) (Stats, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ad := m.adm()
	s := Stats{Countries: map[string]int{}}
	s.Signups, _ = days30(now)
	idx := map[string]int{}
	for i, d := range s.Signups {
		idx[d.Day] = i
	}
	s.SMSDaily, _ = days30(now)
	today := now.UTC().Truncate(24 * time.Hour)
	month := time.Date(now.UTC().Year(), now.UTC().Month(), 1, 0, 0, 0, 0, time.UTC)
	for id, a := range m.accounts {
		s.Users++
		if !a.CreatedAt.Before(today) {
			s.NewToday++
		}
		if a.CreatedAt.After(now.Add(-7 * 24 * time.Hour)) {
			s.New7d++
		}
		if i, ok := idx[a.CreatedAt.UTC().Format("2006-01-02")]; ok {
			s.Signups[i].Count++
		}
		s.Countries[CountryOf(a.Phone)]++
		if t, ok := ad.seen[id]; ok {
			switch d := now.Sub(t); {
			case d <= 24*time.Hour:
				s.Active24h++
				s.Active7d++
				s.Active30d++
			case d <= 7*24*time.Hour:
				s.Active7d++
				s.Active30d++
			case d <= 30*24*time.Hour:
				s.Active30d++
			}
		}
	}
	s.Banned = len(ad.banned)
	for _, r := range m.reports {
		if _, ok := ad.resolved[r.ID]; !ok {
			s.OpenReports++
		}
	}
	for _, e := range ad.sms {
		if !e.at.Before(today) {
			s.SMSToday++
		}
		if !e.at.Before(month) {
			s.SMSMonth++
		}
		if e.at.After(now.Add(-30 * 24 * time.Hour)) {
			s.SMS30d++
		}
		if i, ok := idx[e.at.UTC().Format("2006-01-02")]; ok {
			s.SMSDaily[i].Count++
		}
	}
	for _, a := range m.attach {
		s.Attachments++
		s.AttachBytes += int64(len(a.data))
	}
	return s, nil
}

func (m *Memory) AddAnnouncement(_ context.Context, a Announcement) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.adm().news = append(m.adm().news, a)
	return nil
}

func (m *Memory) DeleteAnnouncement(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	ad := m.adm()
	for i, a := range ad.news {
		if a.ID == id {
			ad.news = append(ad.news[:i], ad.news[i+1:]...)
			return nil
		}
	}
	return ErrNotFound
}

func (m *Memory) Announcements(_ context.Context, limit int) ([]Announcement, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Announcement{}
	n := m.adm().news
	for i := len(n) - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, n[i])
	}
	return out, nil
}

