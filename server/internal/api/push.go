package api

import (
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strings"

	"github.com/klk-app/klk-server/internal/store"
)

// Los tokens de APNs son hexadecimales (hoy 64 caracteres; Apple avisa de que pueden crecer).
var pushTokenRe = regexp.MustCompile(`^[0-9a-f]{32,256}$`)

// setPushToken guarda el token de notificaciones del iPhone que hace la petición.
func (s *Server) setPushToken(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Token string `json:"token"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	token := strings.ToLower(strings.TrimSpace(req.Token))
	if !pushTokenRe.MatchString(token) {
		writeErr(w, http.StatusBadRequest, "bad_token", "token de notificaciones no válido")
		return
	}
	if err := s.store.SetPushToken(r.Context(), dev.AccountID, dev.DeviceID, token); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "dispositivo no encontrado")
			return
		}
		slog.Error("guardar token push", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// clearPushToken deja de enviar notificaciones a este iPhone.
func (s *Server) clearPushToken(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if err := s.store.SetPushToken(r.Context(), dev.AccountID, dev.DeviceID, ""); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		slog.Error("borrar token push", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
