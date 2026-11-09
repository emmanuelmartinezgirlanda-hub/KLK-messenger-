package api

import (
	"net/http"
	"regexp"
	"strings"

	"github.com/klk-app/klk-server/internal/store"
)

// Token de APNs: hexadecimal (64 caracteres hoy, Apple dice que puede crecer).
// Token de FCM: base64url con ":" y similares, hasta ~4 KB.
var (
	apnsTokenRe = regexp.MustCompile(`^[0-9a-fA-F]{32,200}$`)
	fcmTokenRe  = regexp.MustCompile(`^[A-Za-z0-9_:\-\.]+$`)
)

// PUT /v1/push-token: el móvil dice dónde avisarle cuando tenga mensajes.
func (s *Server) setPushToken(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		Platform string `json:"platform"`
		Token    string `json:"token"`
		Lang     string `json:"lang"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	ok := (req.Platform == "apns" && apnsTokenRe.MatchString(req.Token)) ||
		(req.Platform == "fcm" && len(req.Token) >= 20 && len(req.Token) <= 4096 && fcmTokenRe.MatchString(req.Token))
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_token", "token de avisos inválido")
		return
	}
	lang := strings.ToLower(req.Lang)
	if len(lang) > 2 {
		lang = lang[:2]
	}
	if lang == "" {
		lang = "es"
	}
	t := store.PushToken{Platform: req.Platform, Token: strings.ToLower(req.Token), Lang: lang}
	if req.Platform == "fcm" {
		t.Token = req.Token
	}
	if err := s.store.SetPushToken(r.Context(), dev.AccountID, dev.DeviceID, t); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// DELETE /v1/push-token: no quiero más avisos en este móvil.
func (s *Server) deletePushToken(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if err := s.store.DeletePushToken(r.Context(), dev.AccountID, dev.DeviceID); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
