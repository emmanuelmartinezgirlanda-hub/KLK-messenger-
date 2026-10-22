package api

import (
	"log/slog"
	"net/http"

	"github.com/klk-app/klk-server/internal/turn"
)

// GET /v1/turn: servidores para conectar llamadas (STUN siempre; TURN si está configurado).
func (s *Server) turnServers(w http.ResponseWriter, r *http.Request) {
	list := []turn.ICEServer{{URLs: []string{"stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"}}}
	if extra, err := s.TURN.Servers(r.Context()); err != nil {
		slog.Warn("turn", "err", err)
	} else {
		list = append(list, extra...)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"iceServers": list})
}
