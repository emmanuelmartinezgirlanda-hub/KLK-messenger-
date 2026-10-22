package api

import (
	"testing"
	"time"
)

func TestDailyQuota(t *testing.T) {
	var q dailyQuota
	now := time.Date(2026, 10, 22, 10, 0, 0, 0, time.UTC)
	if !q.take("a", 900, 1000, now) || q.take("a", 200, 1000, now) || !q.take("a", 100, 1000, now) {
		t.Fatal("cupo del día")
	}
	if !q.take("b", 1000, 1000, now) {
		t.Fatal("cada cuenta tiene su cupo")
	}
	if !q.take("a", 1000, 1000, now.Add(24*time.Hour)) {
		t.Fatal("al día siguiente se reinicia")
	}
}
