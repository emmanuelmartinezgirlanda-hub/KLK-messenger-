package api

import (
	"context"
	"log/slog"
	"time"
)

// Oferta «Fundadores»: las primeras FoundersMax cuentas reciben KLK Plus gratis
// durante FoundersDays días. Se da una sola vez por cuenta (si ya tuvo Plus, no
// se toca). FoundersMax = 0 la apaga.
func (s *Server) grantFounder(ctx context.Context, accountID string) {
	if s.FoundersMax <= 0 || accountID == "" {
		return
	}
	until, err := s.store.PlusUntil(ctx, accountID)
	if err != nil || !until.IsZero() {
		return
	}
	st, err := s.store.Stats(ctx, time.Now())
	if err != nil || st.Users > s.FoundersMax {
		return
	}
	days := s.FoundersDays
	if days <= 0 {
		days = 365
	}
	if err := s.store.SetPlusUntil(ctx, accountID, time.Now().AddDate(0, 0, days)); err != nil {
		slog.Warn("fundadores", "err", err)
	}
}
