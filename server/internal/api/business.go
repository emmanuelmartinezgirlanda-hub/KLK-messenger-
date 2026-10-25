package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/klk-app/klk-server/internal/store"
)

// KLK Business: cada cuenta puede publicar un perfil de negocio (colmado,
// peluquería…). Es información PÚBLICA que pone el dueño: nombre, tipo,
// horario, dirección y catálogo. Los pedidos y citas NO pasan por aquí:
// viajan cifrados de punta a punta como cualquier mensaje.

// BusinessKinds son los tipos de negocio que entiende la app.
var BusinessKinds = map[string]bool{
	"colmado":    true,
	"peluqueria": true,
	"belleza":    true,
	"comida":     true,
	"tienda":     true,
	"servicios":  true,
	"otro":       true,
}

const (
	maxBusinessData = 64 << 10 // 64 KB: catálogo de ~200 productos
	maxBusinessName = 60
	maxBusinessCity = 60
)

var countryRe = regexp.MustCompile(`^[A-Z]{2}$`)

type businessReq struct {
	Name    string          `json:"name"`
	Kind    string          `json:"kind"`
	Country string          `json:"country"`
	City    string          `json:"city"`
	Data    json.RawMessage `json:"data"`
}

func (s *Server) businessRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/business/me", s.authed(s.myBusiness))
	mux.HandleFunc("PUT /v1/business/me", s.authed(s.putBusiness))
	mux.HandleFunc("DELETE /v1/business/me", s.authed(s.deleteBusiness))
	mux.HandleFunc("GET /v1/business/{id}", s.authed(s.getBusiness))
	mux.HandleFunc("GET /v1/business", s.authed(s.searchBusinesses))
	mux.HandleFunc("POST /v1/business/me/images", s.authed(s.uploadBusinessImage))
	mux.HandleFunc("GET /v1/business/img/{id}", s.getBusinessImage)
	mux.HandleFunc("GET /n/{id}", s.businessPage)
}

// GET /v1/business/me: mi perfil de negocio (404 si no tengo).
func (s *Server) myBusiness(w http.ResponseWriter, r *http.Request) {
	s.writeBusiness(w, r, deviceFrom(r).AccountID)
}

// GET /v1/business/{id}: el perfil de un negocio.
func (s *Server) getBusiness(w http.ResponseWriter, r *http.Request) {
	s.writeBusiness(w, r, r.PathValue("id"))
}

func (s *Server) writeBusiness(w http.ResponseWriter, r *http.Request, id string) {
	b, err := s.store.GetBusiness(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese negocio no existe")
		return
	}
	if err != nil {
		slog.Error("negocio", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, b)
}

// PUT /v1/business/me: crear o cambiar mi perfil de negocio.
func (s *Server) putBusiness(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req businessReq
	r.Body = http.MaxBytesReader(w, r.Body, maxBusinessData+4096)
	if !readJSON(w, r, &req) {
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.City = strings.TrimSpace(req.City)
	n := utf8.RuneCountInString(req.Name)
	switch {
	case n < 2 || n > maxBusinessName:
		writeErr(w, http.StatusBadRequest, "bad_name", "el nombre debe tener entre 2 y 60 letras")
		return
	case !BusinessKinds[req.Kind]:
		writeErr(w, http.StatusBadRequest, "bad_kind", "tipo de negocio no válido")
		return
	case req.Country != "" && !countryRe.MatchString(req.Country):
		writeErr(w, http.StatusBadRequest, "bad_country", "país no válido")
		return
	case utf8.RuneCountInString(req.City) > maxBusinessCity:
		writeErr(w, http.StatusBadRequest, "bad_city", "la ciudad es demasiado larga")
		return
	}
	data := bytes.TrimSpace(req.Data)
	if len(data) == 0 {
		data = []byte("{}")
	}
	var obj map[string]any
	if len(data) > maxBusinessData || json.Unmarshal(data, &obj) != nil || obj == nil {
		writeErr(w, http.StatusBadRequest, "bad_data", "datos del negocio no válidos o demasiado grandes")
		return
	}
	b := store.Business{
		AccountID: dev.AccountID,
		Name:      req.Name,
		Kind:      req.Kind,
		Country:   req.Country,
		City:      req.City,
		Data:      data,
		UpdatedAt: time.Now().UTC(),
	}
	if err := s.store.PutBusiness(r.Context(), b); err != nil {
		slog.Error("guardar negocio", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	s.pruneBusinessImages(r, dev.AccountID, data)
	s.writeBusiness(w, r, dev.AccountID)
}

// DELETE /v1/business/me: dejar de ser negocio (vuelvo a cuenta normal).
func (s *Server) deleteBusiness(w http.ResponseWriter, r *http.Request) {
	acc := deviceFrom(r).AccountID
	if err := s.store.DeleteBusiness(r.Context(), acc); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	// Ya no es negocio: sus fotos dejan de ser públicas.
	if _, err := s.store.PruneBusinessImages(r.Context(), acc, nil, time.Now().Add(time.Minute)); err != nil {
		slog.Warn("borrar fotos de negocio", "err", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/business?q=&kind=&country=: buscar negocios.
func (s *Server) searchBusinesses(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	query := store.BusinessQuery{
		Text:    truncate(strings.TrimSpace(q.Get("q")), 60),
		Kind:    q.Get("kind"),
		Country: q.Get("country"),
		Limit:   50,
	}
	if query.Kind != "" && !BusinessKinds[query.Kind] {
		writeErr(w, http.StatusBadRequest, "bad_kind", "tipo de negocio no válido")
		return
	}
	if query.Country != "" && !countryRe.MatchString(query.Country) {
		writeErr(w, http.StatusBadRequest, "bad_country", "país no válido")
		return
	}
	list, err := s.store.SearchBusinesses(r.Context(), query)
	if err != nil {
		slog.Error("buscar negocios", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"businesses": list})
}

// POST /admin/api/business/{id}/verify y /unverify: el sello de negocio verificado.
func (s *Server) adminVerifyBusiness(w http.ResponseWriter, r *http.Request) {
	v := strings.HasSuffix(r.URL.Path, "/verify")
	err := s.store.SetBusinessVerified(r.Context(), r.PathValue("id"), v)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese negocio no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
