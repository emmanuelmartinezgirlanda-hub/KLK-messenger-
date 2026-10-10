package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	_ "embed"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/store"
)

//go:embed panel/index.html
var panelHTML []byte

const (
	touchEvery       = 5 * time.Minute
	maxNewsTitle     = 80
	maxNewsBody      = 1000
	newsForClients   = 10
	minAdminTokenLen = 16
)

// touch apunta la última conexión como mucho cada 5 minutos por cuenta.
func (s *Server) touch(ctx context.Context, acc string) {
	now := time.Now()
	if t, ok := s.touched.Load(acc); ok && now.Sub(t.(time.Time)) < touchEvery {
		return
	}
	s.touched.Store(acc, now)
	if err := s.store.Touch(ctx, acc, now); err != nil {
		slog.Warn("last_seen", "err", err)
	}
}

// announcements devuelve los últimos avisos de KLK para mostrarlos en la app.
func (s *Server) announcements(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.Announcements(r.Context(), newsForClients)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"announcements": list})
}

// ---------- Panel del dueño ----------

func (s *Server) adminRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /admin", s.panel)
	mux.HandleFunc("GET /admin/", s.panel)
	mux.HandleFunc("GET /admin/api/stats", s.admin(s.adminStats))
	mux.HandleFunc("GET /admin/api/reports", s.admin(s.adminReports))
	mux.HandleFunc("POST /admin/api/reports/{id}/resolve", s.admin(s.adminResolve))
	mux.HandleFunc("GET /admin/api/banned", s.admin(s.adminBanned))
	mux.HandleFunc("POST /admin/api/accounts/{id}/ban", s.admin(s.adminBan))
	mux.HandleFunc("POST /admin/api/accounts/{id}/unban", s.admin(s.adminUnban))
	mux.HandleFunc("POST /admin/api/ban-phone", s.admin(s.adminBanPhone))
	mux.HandleFunc("GET /admin/api/announcements", s.admin(s.adminNewsList))
	mux.HandleFunc("POST /admin/api/announcements", s.admin(s.adminNewsAdd))
	mux.HandleFunc("DELETE /admin/api/announcements/{id}", s.admin(s.adminNewsDelete))
}

func (s *Server) adminEnabled() bool { return len(s.AdminToken) >= minAdminTokenLen }

func (s *Server) panel(w http.ResponseWriter, _ *http.Request) {
	if !s.adminEnabled() {
		http.Error(w, "El panel está desactivado: falta KLK_ADMIN_TOKEN en el servidor.", http.StatusNotFound)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
	w.Write(panelHTML)
}

// admin exige la clave del dueño y limita los intentos por IP.
func (s *Server) admin(next http.HandlerFunc) http.HandlerFunc {
	return s.limitedN(func(w http.ResponseWriter, r *http.Request) {
		if !s.adminEnabled() {
			writeErr(w, http.StatusNotFound, "disabled", "panel desactivado")
			return
		}
		tok, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		a, b := sha256.Sum256([]byte(tok)), sha256.Sum256([]byte(s.AdminToken))
		if subtle.ConstantTimeCompare(a[:], b[:]) != 1 {
			slog.Warn("panel: clave incorrecta")
			writeErr(w, http.StatusUnauthorized, "unauthorized", "clave incorrecta")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r)
	})
}

func (s *Server) adminStats(w http.ResponseWriter, r *http.Request) {
	st, err := s.store.Stats(r.Context(), time.Now())
	if err != nil {
		slog.Error("panel stats", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	online := 0
	if s.hub != nil {
		online = s.hub.OnlineCount()
	}
	smsMonth := float64(st.SMSMonth) * s.SMSPrice
	writeJSON(w, http.StatusOK, map[string]any{
		"stats":  st,
		"online": online,
		"money": map[string]any{
			"smsPrice":      s.SMSPrice,
			"smsCostMonth":  smsMonth,
			"smsCostToday":  float64(st.SMSToday) * s.SMSPrice,
			"serverCost":    s.ServerCost,
			"totalMonth":    smsMonth + s.ServerCost,
			"incomeMonth":   0,
			"plusActive":    false,
			"currency":      "EUR",
		},
	})
}

func (s *Server) adminReports(w http.ResponseWriter, r *http.Request) {
	open := r.URL.Query().Get("all") != "1"
	list, err := s.store.ListReports(r.Context(), open, 200)
	if err != nil {
		slog.Error("panel denuncias", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": list})
}

func (s *Server) adminResolve(w http.ResponseWriter, r *http.Request) {
	err := s.store.ResolveReport(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "denuncia no encontrada o ya resuelta")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminBanned(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.BannedAccounts(r.Context(), 500)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": list})
}

func (s *Server) setBan(w http.ResponseWriter, r *http.Request, acc string, ban bool, reason string) {
	err := s.store.SetBanned(r.Context(), acc, ban, truncate(strings.TrimSpace(reason), 200))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "esa cuenta no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if ban && s.hub != nil {
		s.hub.Kick(acc)
	}
	slog.Info("panel: bloqueo", "banned", ban)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminBan(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Reason string `json:"reason"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	s.setBan(w, r, r.PathValue("id"), true, req.Reason)
}

func (s *Server) adminUnban(w http.ResponseWriter, r *http.Request) {
	s.setBan(w, r, r.PathValue("id"), false, "")
}

func (s *Server) adminBanPhone(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone  string `json:"phone"`
		Reason string `json:"reason"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	phone := strings.ReplaceAll(strings.TrimSpace(req.Phone), " ", "")
	if !auth.ValidPhone(phone) {
		writeErr(w, http.StatusBadRequest, "invalid_phone", "escribe el número con + y el prefijo, p. ej. +18095551234")
		return
	}
	id, err := s.store.AccountIDByPhone(r.Context(), phone)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese número no tiene cuenta en KLK")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	s.setBan(w, r, id, true, req.Reason)
}

func (s *Server) adminNewsList(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.Announcements(r.Context(), 100)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"announcements": list})
}

func (s *Server) adminNewsAdd(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	req.Title, req.Body = strings.TrimSpace(req.Title), strings.TrimSpace(req.Body)
	if req.Title == "" || req.Body == "" {
		writeErr(w, http.StatusBadRequest, "empty", "pon un título y un mensaje")
		return
	}
	if utf8.RuneCountInString(req.Title) > maxNewsTitle || utf8.RuneCountInString(req.Body) > maxNewsBody {
		writeErr(w, http.StatusBadRequest, "too_long", "el título admite 80 letras y el mensaje 1000")
		return
	}
	a := store.Announcement{ID: uuid.NewString(), Title: req.Title, Body: req.Body, CreatedAt: time.Now().UTC()}
	if err := s.store.AddAnnouncement(r.Context(), a); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if s.hub != nil {
		s.hub.Broadcast(map[string]any{"t": "announce", "announcement": a})
	}
	writeJSON(w, http.StatusCreated, a)
}

func (s *Server) adminNewsDelete(w http.ResponseWriter, r *http.Request) {
	err := s.store.DeleteAnnouncement(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese aviso no existe")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
