package api

import (
	"crypto/subtle"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// PlusCode es un código que activa KLK Plus (para el dueño y pruebas).
// Se configuran en KLK_PLUS_CODES: "CODIGO" (10 años) o "CODIGO:30" (30 días).
type PlusCode struct {
	Code string
	Days int
}

// ParsePlusCodes lee la lista de códigos de la variable de entorno.
func ParsePlusCodes(v string) []PlusCode {
	var out []PlusCode
	for _, part := range strings.Split(v, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		code, days := part, 3650
		if i := strings.LastIndex(part, ":"); i > 0 {
			if d, err := strconv.Atoi(part[i+1:]); err == nil && d > 0 {
				code, days = part[:i], d
			}
		}
		if len(code) >= 6 {
			out = append(out, PlusCode{Code: strings.ToUpper(code), Days: days})
		}
	}
	return out
}

type plusView struct {
	Active bool       `json:"active"`
	Until  *time.Time `json:"until,omitempty"`
}

func (s *Server) plusOf(r *http.Request, acc string) (plusView, error) {
	t, err := s.store.PlusUntil(r.Context(), acc)
	if err != nil {
		return plusView{}, err
	}
	if t.IsZero() {
		return plusView{}, nil
	}
	return plusView{Active: t.After(time.Now()), Until: &t}, nil
}

// GET /v1/plus: ¿tengo KLK Plus?
func (s *Server) plusStatus(w http.ResponseWriter, r *http.Request) {
	// Quien ya tenía cuenta antes de la oferta también es fundador.
	s.grantFounder(r.Context(), deviceFrom(r).AccountID)
	v, err := s.plusOf(r, deviceFrom(r).AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, v)
}

// POST /v1/plus/redeem {"code"}: activa Plus con un código.
func (s *Server) plusRedeem(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	given := strings.ToUpper(strings.TrimSpace(req.Code))
	var match *PlusCode
	for i := range s.PlusCodes {
		c := &s.PlusCodes[i]
		if len(given) == len(c.Code) && subtle.ConstantTimeCompare([]byte(given), []byte(c.Code)) == 1 {
			match = c
		}
	}
	if match == nil {
		writeErr(w, http.StatusBadRequest, "bad_code", "ese código no es válido")
		return
	}
	now := time.Now()
	from := now
	if cur, err := s.store.PlusUntil(r.Context(), dev.AccountID); err == nil && cur.After(now) {
		from = cur // si ya tenía Plus, se suma
	}
	until := from.Add(time.Duration(match.Days) * 24 * time.Hour)
	if err := s.store.SetPlusUntil(r.Context(), dev.AccountID, until); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, plusView{Active: true, Until: &until})
}

// POST /v1/plus/apple {"jws":["…"]}: compras (o renovaciones) de KLK Plus
// hechas con Apple. Apple cobra y nos paga; aquí solo comprobamos la firma.
func (s *Server) plusApple(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		JWS []string `json:"jws"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if s.Apple == nil || len(req.JWS) == 0 || len(req.JWS) > 20 {
		writeErr(w, http.StatusBadRequest, "bad_purchase", "compra no válida")
		return
	}
	now := time.Now()
	best := time.Time{}
	taken := false
	for _, j := range req.JWS {
		tx, err := s.Apple.Verify(j, now)
		if err != nil || tx.BundleID != s.AppleBundleID || !strings.HasPrefix(tx.ProductID, "klk.plus") ||
			tx.RevocationDate != 0 || tx.OriginalTransactionID == "" {
			continue
		}
		if tx.AppAccountToken != "" && !strings.EqualFold(tx.AppAccountToken, dev.AccountID) {
			taken = true
			continue
		}
		exp := tx.Expires()
		if !exp.After(now) {
			continue
		}
		owner, err := s.store.ClaimAppleSub(r.Context(), tx.OriginalTransactionID, dev.AccountID, exp)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "error interno")
			return
		}
		if owner != dev.AccountID {
			taken = true
			continue
		}
		if exp.After(best) {
			best = exp
		}
	}
	if best.IsZero() {
		if taken {
			writeErr(w, http.StatusConflict, "other_account", "esa suscripción es de otra cuenta de KLK")
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_purchase", "no hay una suscripción activa")
		return
	}
	cur, err := s.store.PlusUntil(r.Context(), dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	until := best
	if cur.After(until) {
		until = cur // p. ej. un código de 10 años
	} else if err := s.store.SetPlusUntil(r.Context(), dev.AccountID, until); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, plusView{Active: true, Until: &until})
}
