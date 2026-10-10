package store

import (
	"context"
	"sort"
)

func (m *Memory) commLocked() map[string]map[string]bool {
	if m.communities == nil {
		m.communities = map[string]map[string]bool{}
	}
	return m.communities
}

func (m *Memory) JoinCommunity(_ context.Context, community, accountID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[accountID]; !ok {
		return ErrNotFound
	}
	c := m.commLocked()
	if c[community] == nil {
		c[community] = map[string]bool{}
	}
	c[community][accountID] = true
	return nil
}

func (m *Memory) LeaveCommunity(_ context.Context, community, accountID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.commLocked()[community], accountID)
	return nil
}

func (m *Memory) bannedLocked(accountID string) bool {
	_, b := m.adm().banned[accountID]
	return b
}

func (m *Memory) CommunityCounts(_ context.Context) (map[string]int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := map[string]int{}
	for c, members := range m.commLocked() {
		for acc := range members {
			if !m.bannedLocked(acc) {
				out[c]++
			}
		}
	}
	return out, nil
}

func (m *Memory) CommunitiesOf(_ context.Context, accountID string) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []string{}
	for c, members := range m.commLocked() {
		if members[accountID] {
			out = append(out, c)
		}
	}
	sort.Strings(out)
	return out, nil
}

func (m *Memory) CommunityMembers(_ context.Context, community string, limit int) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []string{}
	for acc := range m.commLocked()[community] {
		if !m.bannedLocked(acc) {
			out = append(out, acc)
		}
	}
	sort.Strings(out)
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
