package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/klk-app/klk-server/internal/playstore"
	"github.com/klk-app/klk-server/internal/store"
)

// Anuncios de negocios que pasan solos arriba de los chats. Los pone el dueño
// desde su panel (con foto o logo). Se guardan en los ajustes del dueño.

const (
	adsKey      = "ads"
	maxAds      = 20
	maxAdTitle  = 40
	maxAdBody   = 120
	maxAdCTA    = 16
	maxAdURL    = 300
	maxAdDays   = 365
	adsForUsers = 12
)

type ad struct {
	ID        string     `json:"id"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	CTA       string     `json:"cta"`
	URL       string     `json:"url"`
	Color     string     `json:"color"`
	Until     *time.Time `json:"until,omitempty"`
	CreatedAt time.Time  `json:"createdAt"`
	Image     []byte     `json:"image,omitempty"`
	ImageV    int        `json:"imageV"`
	Clicks    int        `json:"clicks"`

	// Anuncios que pone un negocio desde la app (pagando la suscripción «KLK Anuncios»).
	OwnerID   string     `json:"ownerId,omitempty"`
	Status    string     `json:"status,omitempty"` // "" o "active" = sale · "pending" = falta aprobarlo · "rejected"
	Note      string     `json:"note,omitempty"`   // por qué se rechazó
	PaidUntil *time.Time `json:"paidUntil,omitempty"`
}

// adView es lo que ve la app (sin la foto: se baja aparte).
type adView struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	CTA      string `json:"cta"`
	URL      string `json:"url"`
	Color    string `json:"color"`
	HasImage bool   `json:"hasImage"`
	ImageV   int    `json:"imageV"`
	Clicks   int    `json:"clicks,omitempty"`
	Until    string `json:"until,omitempty"`
	Status   string `json:"status,omitempty"`
	Note     string `json:"note,omitempty"`
	Owner    string `json:"owner,omitempty"`
	Paid     string `json:"paidUntil,omitempty"`
	// Chat: la cuenta del negocio (para escribirle en KLK al tocar el anuncio).
	Chat string `json:"chat,omitempty"`
}

func (a ad) view(admin bool) adView {
	v := adView{ID: a.ID, Title: a.Title, Body: a.Body, CTA: a.CTA, URL: a.URL, Color: a.Color, HasImage: len(a.Image) > 0, ImageV: a.ImageV, Chat: a.OwnerID}
	if admin {
		v.Clicks = a.Clicks
		if a.Until != nil {
			v.Until = a.Until.Format("2006-01-02")
		}
		v.Status = a.Status
		if v.Status == "" {
			v.Status = "active"
		}
		v.Note = a.Note
		v.Owner = a.OwnerID
		if a.PaidUntil != nil {
			v.Paid = a.PaidUntil.Format("2006-01-02")
		}
	}
	return v
}

func (s *Server) loadAds(r *http.Request) ([]ad, error) {
	raw, err := s.store.OwnerSetting(r.Context(), adsKey)
	if errors.Is(err, store.ErrNotFound) {
		return []ad{}, nil
	}
	if err != nil {
		return nil, err
	}
	var list []ad
	if err := json.Unmarshal(raw, &list); err != nil {
		return []ad{}, nil
	}
	return list, nil
}

func (s *Server) saveAds(r *http.Request, list []ad) error {
	raw, err := json.Marshal(list)
	if err != nil {
		return err
	}
	return s.store.SetOwnerSetting(r.Context(), adsKey, raw)
}

// live dice si el anuncio sale ahora mismo.
func (a ad) live(now time.Time) bool {
	if a.Status != "" && a.Status != "active" {
		return false
	}
	if a.Until != nil && now.After(*a.Until) {
		return false
	}
	if a.OwnerID != "" && (a.PaidUntil == nil || now.After(*a.PaidUntil)) {
		return false
	}
	return true
}

// activeAds quita los del dueño ya caducados (los de negocios se quedan
// guardados aunque no salgan, para que puedan renovar).
func activeAds(list []ad, now time.Time) []ad {
	out := []ad{}
	for _, a := range list {
		if a.OwnerID == "" && a.Until != nil && now.After(*a.Until) {
			continue
		}
		out = append(out, a)
	}
	return out
}

// GET /v1/ads: los anuncios que están en marcha.
func (s *Server) ads(w http.ResponseWriter, r *http.Request) {
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	now := time.Now()
	live := []ad{}
	for _, a := range list {
		if a.live(now) {
			live = append(live, a)
		}
	}
	// Si hay muchos, cada vez salen otros (al azar).
	rand.Shuffle(len(live), func(i, j int) { live[i], live[j] = live[j], live[i] })
	out := []adView{}
	for _, a := range live {
		if len(out) == adsForUsers {
			break
		}
		out = append(out, a.view(false))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ads": out})
}

// GET /v1/ads/{id}/image: la foto o el logo del anuncio (público).
func (s *Server) adImage(w http.ResponseWriter, r *http.Request) {
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	for _, a := range list {
		if a.ID == r.PathValue("id") && len(a.Image) > 0 {
			ct := "image/jpeg"
			if bytes.HasPrefix(a.Image, []byte("\x89PNG")) {
				ct = "image/png"
			}
			w.Header().Set("Content-Type", ct)
			w.Header().Set("Cache-Control", "public, max-age=86400")
			_, _ = w.Write(a.Image)
			return
		}
	}
	writeErr(w, http.StatusNotFound, "not_found", "sin foto")
}

// POST /v1/ads/{id}/click: cuenta cuántas veces tocaron el anuncio.
func (s *Server) adClick(w http.ResponseWriter, r *http.Request) {
	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err == nil {
		for i := range list {
			if list[i].ID == r.PathValue("id") {
				list[i].Clicks++
				_ = s.saveAds(r, list)
				break
			}
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Panel del dueño ----------

func (s *Server) adminAds(w http.ResponseWriter, r *http.Request) {
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	out := []adView{}
	for _, a := range list {
		out = append(out, a.view(true))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ads": out})
}

var adColors = map[string]bool{"red": true, "blue": true, "navy": true, "green": true, "purple": true, "orange": true, "black": true}

func (s *Server) adminAddAd(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title string `json:"title"`
		Body  string `json:"body"`
		CTA   string `json:"cta"`
		URL   string `json:"url"`
		Color string `json:"color"`
		Days  int    `json:"days"`
		Image []byte `json:"image"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.Title, req.Body = strings.TrimSpace(req.Title), strings.TrimSpace(req.Body)
	req.CTA, req.URL = strings.TrimSpace(req.CTA), strings.TrimSpace(req.URL)
	if req.Title == "" || req.Body == "" {
		writeErr(w, http.StatusBadRequest, "empty", "pon el nombre del negocio y el mensaje")
		return
	}
	if utf8.RuneCountInString(req.Title) > maxAdTitle || utf8.RuneCountInString(req.Body) > maxAdBody ||
		utf8.RuneCountInString(req.CTA) > maxAdCTA || len(req.URL) > maxAdURL {
		writeErr(w, http.StatusBadRequest, "too_long", "nombre hasta 40 letras, mensaje hasta 120 y botón hasta 16")
		return
	}
	if req.URL != "" && !strings.HasPrefix(req.URL, "https://") && !strings.HasPrefix(req.URL, "http://") &&
		!strings.HasPrefix(req.URL, "tel:") && !strings.HasPrefix(req.URL, "@") && !strings.HasPrefix(req.URL, "klk:") {
		req.URL = "https://" + req.URL
	}
	if req.CTA == "" {
		req.CTA = "Ver"
	}
	if !adColors[req.Color] {
		req.Color = "red"
	}
	if len(req.Image) > 0 && (len(req.Image) > maxChanImage || !validJPEGorPNG(req.Image)) {
		writeErr(w, http.StatusBadRequest, "bad_image", "esa foto no vale (JPEG o PNG, hasta 400 KB)")
		return
	}
	a := ad{ID: uuid.NewString(), Title: req.Title, Body: req.Body, CTA: req.CTA, URL: req.URL, Color: req.Color,
		CreatedAt: time.Now().UTC(), Image: req.Image}
	if len(req.Image) > 0 {
		a.ImageV = 1
	}
	if req.Days > 0 {
		if req.Days > maxAdDays {
			req.Days = maxAdDays
		}
		u := time.Now().UTC().Add(time.Duration(req.Days) * 24 * time.Hour)
		a.Until = &u
	}
	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	list = activeAds(list, time.Now())
	if countAds(list, false) >= maxAds {
		writeErr(w, http.StatusBadRequest, "too_many", "ya hay 20 anuncios: borra alguno primero")
		return
	}
	list = append([]ad{a}, list...)
	if err := s.saveAds(r, list); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusCreated, a.view(true))
}

func (s *Server) adminDeleteAd(w http.ResponseWriter, r *http.Request) {
	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	out := list[:0]
	found := false
	for _, a := range list {
		if a.ID == r.PathValue("id") {
			found = true
			continue
		}
		out = append(out, a)
	}
	if !found {
		writeErr(w, http.StatusNotFound, "not_found", "ese anuncio no existe")
		return
	}
	if err := s.saveAds(r, out); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/gif/key: la clave de KLIPY para que la app busque GIF.
// KLIPY pide que las búsquedas salgan del móvil de cada persona, no del servidor.
func (s *Server) gifKey(w http.ResponseWriter, r *http.Request) {
	if s.GifKey == "" {
		writeErr(w, http.StatusNotFound, "no_gif", "los GIF todavía no están activados")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"key": s.GifKey, "provider": "klipy"})
}

// ---------- Anuncios que pone cada negocio desde la app ----------

const (
	maxUserAds     = 80
	maxUserAdImage = 150 * 1024
	adsProductPref = "klk.ads"
)

func countAds(list []ad, users bool) int {
	n := 0
	for _, a := range list {
		if (a.OwnerID != "") == users {
			n++
		}
	}
	return n
}

// adPaidUntil comprueba con Apple o Google la suscripción «KLK Anuncios» y
// devuelve hasta cuándo está pagada (cero si no hay ninguna activa).
func (s *Server) adPaidUntil(r *http.Request, acc string, jws, tokens []string) (time.Time, bool, error) {
	now := time.Now()
	best := time.Time{}
	taken := false
	if s.Apple != nil {
		for _, j := range jws {
			tx, err := s.Apple.Verify(j, now)
			if err != nil || tx.BundleID != s.AppleBundleID || !strings.HasPrefix(tx.ProductID, adsProductPref) ||
				tx.RevocationDate != 0 || tx.OriginalTransactionID == "" {
				continue
			}
			if tx.AppAccountToken != "" && !strings.EqualFold(tx.AppAccountToken, acc) {
				taken = true
				continue
			}
			exp := tx.Expires()
			if !exp.After(now) {
				continue
			}
			owner, err := s.store.ClaimAppleSub(r.Context(), "ad:"+tx.OriginalTransactionID, acc, exp)
			if err != nil {
				return time.Time{}, false, err
			}
			if owner != acc {
				taken = true
				continue
			}
			if exp.After(best) {
				best = exp
			}
		}
	}
	if s.Play != nil {
		for _, tok := range tokens {
			if tok == "" || len(tok) > 4096 {
				continue
			}
			sub, err := s.Play.Subscription(r.Context(), tok)
			if err != nil {
				if !errors.Is(err, playstore.ErrNotFound) {
					slog.Warn("Google Play (anuncios)", "err", err)
				}
				continue
			}
			if !strings.HasPrefix(sub.ProductID, adsProductPref) || !sub.Entitled(now) {
				continue
			}
			if sub.AccountID != "" && !strings.EqualFold(sub.AccountID, acc) {
				taken = true
				continue
			}
			owner, err := s.store.ClaimAppleSub(r.Context(), "adgp:"+tok, acc, sub.Expires)
			if err != nil {
				return time.Time{}, false, err
			}
			if owner != acc {
				taken = true
				continue
			}
			if !sub.Acknowledged {
				if err := s.Play.Acknowledge(r.Context(), sub.ProductID, tok); err != nil {
					slog.Warn("Google Play: no se pudo confirmar la compra del anuncio", "err", err)
				}
			}
			if sub.Expires.After(best) {
				best = sub.Expires
			}
		}
	}
	return best, taken, nil
}

func mineView(a *ad) map[string]any {
	if a == nil {
		return map[string]any{"ad": nil}
	}
	return map[string]any{"ad": a.view(true)}
}

// GET /v1/ads/mine: mi anuncio (si tengo).
func (s *Server) myAd(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	for i := range list {
		if list[i].OwnerID == dev.AccountID {
			writeJSON(w, http.StatusOK, mineView(&list[i]))
			return
		}
	}
	writeJSON(w, http.StatusOK, mineView(nil))
}

// POST /v1/ads/mine: crear o cambiar mi anuncio. Hace falta la suscripción
// «KLK Anuncios» (Apple: "jws"; Google Play: "tokens"). Cada cambio vuelve a
// pasar por la aprobación del dueño de KLK.
func (s *Server) saveMyAd(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Title     string   `json:"title"`
		Body      string   `json:"body"`
		CTA       string   `json:"cta"`
		URL       string   `json:"url"`
		Color     string   `json:"color"`
		Image     []byte   `json:"image"`
		KeepImage bool     `json:"keepImage"`
		JWS       []string `json:"jws"`
		Tokens    []string `json:"tokens"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if len(req.JWS) > 20 || len(req.Tokens) > 10 {
		writeErr(w, http.StatusBadRequest, "bad_purchase", "compra no válida")
		return
	}
	req.Title, req.Body = strings.TrimSpace(req.Title), strings.TrimSpace(req.Body)
	req.CTA, req.URL = strings.TrimSpace(req.CTA), strings.TrimSpace(req.URL)
	if req.Title == "" || req.Body == "" {
		writeErr(w, http.StatusBadRequest, "empty", "pon el nombre del negocio y el mensaje")
		return
	}
	if utf8.RuneCountInString(req.Title) > maxAdTitle || utf8.RuneCountInString(req.Body) > maxAdBody ||
		utf8.RuneCountInString(req.CTA) > maxAdCTA || len(req.URL) > maxAdURL {
		writeErr(w, http.StatusBadRequest, "too_long", "nombre hasta 40 letras, mensaje hasta 120 y botón hasta 16")
		return
	}
	if req.URL != "" && !strings.HasPrefix(req.URL, "https://") && !strings.HasPrefix(req.URL, "http://") &&
		!strings.HasPrefix(req.URL, "tel:") && !strings.HasPrefix(req.URL, "@") {
		req.URL = "https://" + req.URL
	}
	if req.CTA == "" {
		req.CTA = "Ver"
	}
	if !adColors[req.Color] {
		req.Color = "red"
	}
	if len(req.Image) > 0 && (len(req.Image) > maxUserAdImage || !validJPEGorPNG(req.Image)) {
		writeErr(w, http.StatusBadRequest, "bad_image", "ese logo no vale (JPEG o PNG, hasta 150 KB)")
		return
	}
	paid, taken, err := s.adPaidUntil(r, dev.AccountID, req.JWS, req.Tokens)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}

	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	list = activeAds(list, time.Now())
	idx := -1
	for i := range list {
		if list[i].OwnerID == dev.AccountID {
			idx = i
			break
		}
	}
	var cur ad
	if idx >= 0 {
		cur = list[idx]
	} else {
		if countAds(list, true) >= maxUserAds {
			writeErr(w, http.StatusServiceUnavailable, "full", "ahora mismo no caben más anuncios; prueba en unos días")
			return
		}
		cur = ad{ID: uuid.NewString(), OwnerID: dev.AccountID, CreatedAt: time.Now().UTC()}
	}
	if !paid.IsZero() && (cur.PaidUntil == nil || paid.After(*cur.PaidUntil)) {
		p := paid.UTC()
		cur.PaidUntil = &p
	}
	if cur.PaidUntil == nil || time.Now().After(*cur.PaidUntil) {
		if taken {
			writeErr(w, http.StatusConflict, "other_account", "esa suscripción es de otra cuenta de KLK")
			return
		}
		writeErr(w, http.StatusPaymentRequired, "need_payment", "hace falta la suscripción de KLK Anuncios")
		return
	}
	cur.Title, cur.Body, cur.CTA, cur.URL, cur.Color = req.Title, req.Body, req.CTA, req.URL, req.Color
	if len(req.Image) > 0 {
		cur.Image = req.Image
		cur.ImageV++
	} else if !req.KeepImage {
		cur.Image = nil
	}
	cur.Status = "pending"
	cur.Note = ""
	if idx >= 0 {
		list[idx] = cur
	} else {
		list = append(list, cur)
	}
	if err := s.saveAds(r, list); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, mineView(&cur))
}

// POST /v1/ads/mine/renew: la tienda renovó la suscripción; alarga el anuncio.
func (s *Server) renewMyAd(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		JWS    []string `json:"jws"`
		Tokens []string `json:"tokens"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if len(req.JWS) > 20 || len(req.Tokens) > 10 {
		writeErr(w, http.StatusBadRequest, "bad_purchase", "compra no válida")
		return
	}
	paid, _, err := s.adPaidUntil(r, dev.AccountID, req.JWS, req.Tokens)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	for i := range list {
		if list[i].OwnerID != dev.AccountID {
			continue
		}
		if !paid.IsZero() && (list[i].PaidUntil == nil || paid.After(*list[i].PaidUntil)) {
			p := paid.UTC()
			list[i].PaidUntil = &p
			if err := s.saveAds(r, list); err != nil {
				writeErr(w, http.StatusInternalServerError, "internal", "error interno")
				return
			}
		}
		writeJSON(w, http.StatusOK, mineView(&list[i]))
		return
	}
	writeJSON(w, http.StatusOK, mineView(nil))
}

// DELETE /v1/ads/mine: quitar mi anuncio (la suscripción se cancela en la tienda).
func (s *Server) deleteMyAd(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	s.adsMu.Lock()
	defer s.adsMu.Unlock()
	list, err := s.loadAds(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	out := list[:0]
	for _, a := range list {
		if a.OwnerID != dev.AccountID {
			out = append(out, a)
		}
	}
	if err := s.saveAds(r, out); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /admin/api/ads/{id}/approve y /reject {"note":"…"}: el dueño de KLK
// revisa los anuncios de los negocios antes de que salgan.
func (s *Server) adminReviewAd(approve bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Note string `json:"note"`
		}
		if r.ContentLength > 0 && !readJSON(w, r, &req) {
			return
		}
		s.adsMu.Lock()
		defer s.adsMu.Unlock()
		list, err := s.loadAds(r)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "error interno")
			return
		}
		for i := range list {
			if list[i].ID != r.PathValue("id") {
				continue
			}
			if approve {
				list[i].Status = "active"
				list[i].Note = ""
			} else {
				list[i].Status = "rejected"
				note := strings.TrimSpace(req.Note)
				if utf8.RuneCountInString(note) > 200 {
					note = string([]rune(note)[:200])
				}
				list[i].Note = note
			}
			if err := s.saveAds(r, list); err != nil {
				writeErr(w, http.StatusInternalServerError, "internal", "error interno")
				return
			}
			writeJSON(w, http.StatusOK, list[i].view(true))
			return
		}
		writeErr(w, http.StatusNotFound, "not_found", "ese anuncio no existe")
	}
}
