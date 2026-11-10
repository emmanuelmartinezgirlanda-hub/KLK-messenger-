package api

import (
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// Letras sin las que se confunden (0/O, 1/I/L).
const giftAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// newGiftCode inventa un código como KLK-7QX2-M9HD.
func newGiftCode() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := []byte("KLK-")
	for i, c := range b {
		if i == 4 {
			out = append(out, '-')
		}
		out = append(out, giftAlphabet[int(c)%len(giftAlphabet)])
	}
	return string(out), nil
}

// GET /admin/api/plus: cuentas con Plus y códigos de regalo.
func (s *Server) adminPlus(w http.ResponseWriter, r *http.Request) {
	accs, err := s.store.PlusAccounts(r.Context(), time.Now(), 500)
	if err != nil {
		slog.Error("panel plus", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	codes, err := s.store.GiftCodes(r.Context(), 200)
	if err != nil {
		slog.Error("panel códigos", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": accs, "codes": codes})
}

// POST /admin/api/plus/codes {"days":90}: crea un código de regalo de un solo uso.
func (s *Server) adminNewGiftCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Days int `json:"days"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.Days <= 0 || req.Days > 366 {
		writeErr(w, http.StatusBadRequest, "bad_days", "los días van de 1 a 366")
		return
	}
	for try := 0; try < 5; try++ {
		code, err := newGiftCode()
		if err != nil {
			break
		}
		err = s.store.AddGiftCode(r.Context(), code, req.Days, time.Now())
		if errors.Is(err, store.ErrCodeExists) {
			continue
		}
		if err != nil {
			break
		}
		writeJSON(w, http.StatusOK, map[string]any{"code": code, "days": req.Days})
		return
	}
	writeErr(w, http.StatusInternalServerError, "internal", "error interno")
}

// POST /admin/api/accounts/{id}/plus/remove: le quita Plus a una cuenta.
// Se deja vencido (no vacío) para que la oferta «Fundadores» no se lo vuelva a dar.
func (s *Server) adminRemovePlus(w http.ResponseWriter, r *http.Request) {
	err := s.store.SetPlusUntil(r.Context(), r.PathValue("id"), time.Now().Add(-time.Second))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "esa cuenta no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /admin/api/plus/grant {"who":"+1809… | correo | @usuario","days":90}:
// le da Plus directamente a una cuenta (sin código). Si ya tenía, se alarga.
func (s *Server) adminGrantPlus(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Who  string `json:"who"`
		Days int    `json:"days"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.Days <= 0 || req.Days > 3660 {
		writeErr(w, http.StatusBadRequest, "bad_days", "los días van de 1 a 3660")
		return
	}
	who := strings.TrimSpace(req.Who)
	var acc string
	var err error
	switch {
	case strings.HasPrefix(who, "@"):
		acc, err = s.store.AccountByUsername(r.Context(), NormalizeUsername(who))
	case strings.Contains(who, "@"):
		acc, err = s.store.AccountIDByPhone(r.Context(), "mail:"+strings.ToLower(who))
	default:
		phone := strings.Map(func(c rune) rune {
			if c >= '0' && c <= '9' {
				return c
			}
			return -1
		}, who)
		if phone == "" {
			writeErr(w, http.StatusBadRequest, "bad_who", "escribe un número, un correo o un @usuario")
			return
		}
		acc, err = s.store.AccountIDByPhone(r.Context(), "+"+phone)
	}
	if err != nil || acc == "" {
		writeErr(w, http.StatusNotFound, "not_found", "no encontré esa cuenta en KLK")
		return
	}
	if err := s.addPlusDays(r, acc, req.Days); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	until, _ := s.store.PlusUntil(r.Context(), acc)
	writeJSON(w, http.StatusOK, map[string]any{"until": until})
}
