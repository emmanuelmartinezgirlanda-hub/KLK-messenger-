package api

import (
	"net/http"
	"os"
	"time"
)

// ServiceCheck es el estado de un servicio externo al arrancar (SMS, correo…).
type ServiceCheck struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

var startedAt = time.Now()

// GET /admin/api/services: estado del servidor y de sus servicios, para el panel.
func (s *Server) adminServices(w http.ResponseWriter, r *http.Request) {
	dbOK := true
	if _, err := s.store.AccountExists(r.Context(), "00000000-0000-0000-0000-000000000000"); err != nil {
		dbOK = false
	}
	checks := append([]ServiceCheck{{Name: "Base de datos", OK: dbOK, Detail: map[bool]string{true: "responde", false: "no responde"}[dbOK]}}, s.Health...)
	commit := os.Getenv("RENDER_GIT_COMMIT")
	if len(commit) > 7 {
		commit = commit[:7]
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"startedAt": startedAt,
		"commit":    commit,
		"checks":    checks,
	})
}
