package api

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// Invita a tus amigos: cada 3 amigos que se unen con tu código = 1 mes de
// KLK Plus. Quien llega con un código también se lleva 7 días de Plus.
const (
	invitesPerReward = 3
	inviteRewardDays = 30
	inviteeBonusDays = 7
	inviteMaxAge     = 14 * 24 * time.Hour // el código se pone al empezar
)

type inviteView struct {
	Code      string `json:"code"`
	Count     int    `json:"count"`
	PerReward int    `json:"perReward"`
	Months    int    `json:"months"`    // meses de Plus ganados
	Next      int    `json:"next"`      // cuántos faltan para el próximo mes
	InvitedBy bool   `json:"invitedBy"` // ya usé el código de alguien
	CanClaim  bool   `json:"canClaim"`  // aún puedo poner un código
}

func (s *Server) inviteOf(r *http.Request, acc string) (inviteView, error) {
	ctx := r.Context()
	code, err := s.store.InviteCode(ctx, acc)
	if err != nil {
		return inviteView{}, err
	}
	n, err := s.store.InviteCount(ctx, acc)
	if err != nil {
		return inviteView{}, err
	}
	by, err := s.store.InvitedBy(ctx, acc)
	if err != nil {
		return inviteView{}, err
	}
	created, err := s.store.AccountCreated(ctx, acc)
	if err != nil {
		return inviteView{}, err
	}
	return inviteView{
		Code: code, Count: n, PerReward: invitesPerReward,
		Months: n / invitesPerReward, Next: invitesPerReward - n%invitesPerReward,
		InvitedBy: by != "", CanClaim: by == "" && time.Since(created) < inviteMaxAge,
	}, nil
}

// GET /v1/invite: mi código y cuántos amigos se unieron.
func (s *Server) inviteStatus(w http.ResponseWriter, r *http.Request) {
	v, err := s.inviteOf(r, deviceFrom(r).AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// addPlusDays suma días de Plus a una cuenta (si ya tenía, se alarga).
func (s *Server) addPlusDays(r *http.Request, acc string, days int) error {
	now := time.Now()
	from := now
	if cur, err := s.store.PlusUntil(r.Context(), acc); err == nil && cur.After(now) {
		from = cur
	}
	return s.store.SetPlusUntil(r.Context(), acc, from.Add(time.Duration(days)*24*time.Hour))
}

// POST /v1/invite/claim {"code"}: me uní gracias a un amigo.
func (s *Server) inviteClaim(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	code = strings.ReplaceAll(code, " ", "")
	if !strings.HasPrefix(code, "KLK") && len(code) == 6 {
		code = "KLK" + code
	}
	if len(code) < 6 || len(code) > 20 {
		writeErr(w, http.StatusBadRequest, "bad_code", "ese código no existe")
		return
	}
	inviter, n, err := s.store.ClaimInvite(r.Context(), code, dev.AccountID, time.Now(), inviteMaxAge)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusBadRequest, "bad_code", "ese código no existe")
		return
	case errors.Is(err, store.ErrSelfInvite):
		writeErr(w, http.StatusBadRequest, "own_code", "ese es tu propio código: compártelo con tus amigos")
		return
	case errors.Is(err, store.ErrAlreadyInvited):
		writeErr(w, http.StatusConflict, "already", "ya usaste un código de invitación")
		return
	case errors.Is(err, store.ErrTooLate):
		writeErr(w, http.StatusBadRequest, "too_late", "el código de un amigo solo se puede poner en tus primeros 14 días en KLK")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if err := s.addPlusDays(r, dev.AccountID, inviteeBonusDays); err != nil {
		slog.Warn("invitación: plus del invitado", "err", err)
	}
	if n%invitesPerReward == 0 {
		if err := s.addPlusDays(r, inviter, inviteRewardDays); err != nil {
			slog.Warn("invitación: plus de quien invita", "err", err)
		}
	}
	v, err := s.inviteOf(r, dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"invite": v, "bonusDays": inviteeBonusDays})
}
