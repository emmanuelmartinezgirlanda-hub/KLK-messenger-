package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

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
}

func (a ad) view(admin bool) adView {
	v := adView{ID: a.ID, Title: a.Title, Body: a.Body, CTA: a.CTA, URL: a.URL, Color: a.Color, HasImage: len(a.Image) > 0, ImageV: a.ImageV}
	if admin {
		v.Clicks = a.Clicks
		if a.Until != nil {
			v.Until = a.Until.Format("2006-01-02")
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

func activeAds(list []ad, now time.Time) []ad {
	out := []ad{}
	for _, a := range list {
		if a.Until != nil && now.After(*a.Until) {
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
	out := []adView{}
	for _, a := range activeAds(list, time.Now()) {
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
		!strings.HasPrefix(req.URL, "tel:") && !strings.HasPrefix(req.URL, "klk:") {
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
	if len(list) >= maxAds {
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
