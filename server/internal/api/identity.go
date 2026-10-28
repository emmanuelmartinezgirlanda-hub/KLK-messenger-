package api

import (
	"errors"
	"html/template"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/store"
)

// @usuario y correo: para encontrar a alguien sin su número y para entrar con
// correo (o recuperar la cuenta si pierdes el número).

const (
	maxMailPerIPDay  = 15 // correos con código por conexión y día
	maxMailPerAccDay = 6  // para añadir el correo a una cuenta
)

var usernameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_.]{2,19}$`)

// Nombres que no se pueden coger (para que nadie se haga pasar por KLK).
var reservedUsernames = map[string]bool{
	"klk": true, "klkmessenger": true, "klk_messenger": true, "klk.messenger": true, "admin": true,
	"administrador": true, "soporte": true, "support": true, "ayuda": true, "help": true, "oficial": true,
	"official": true, "apple": true, "google": true, "root": true, "sistema": true, "system": true,
	"moderador": true, "moderator": true, "seguridad": true, "security": true, "equipo": true, "team": true,
}

// NormalizeUsername quita la @ y lo pasa a minúsculas.
func NormalizeUsername(u string) string {
	return strings.ToLower(strings.TrimPrefix(strings.TrimSpace(u), "@"))
}

func validUsername(u string) bool {
	return usernameRe.MatchString(u) && !strings.Contains(u, "..") && !strings.HasSuffix(u, ".") &&
		!reservedUsernames[u] && !strings.HasPrefix(u, "klk")
}

func (s *Server) identityRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/verification/methods", s.verificationMethods)
	mux.HandleFunc("POST /v1/verification/email/request", s.limited(s.requestEmailCode))
	// Cada código admite 5 intentos y pedirlo ya está limitado: aquí no hace falta más.
	mux.HandleFunc("POST /v1/verification/email/verify", s.verifyEmail)

	mux.HandleFunc("GET /v1/account/me", s.authed(s.accountMe))
	mux.HandleFunc("PUT /v1/account/username", s.authed(s.setUsername))
	mux.HandleFunc("POST /v1/account/email/request", s.authed(s.requestLinkEmail))
	mux.HandleFunc("POST /v1/account/email/verify", s.authed(s.verifyLinkEmail))
	mux.HandleFunc("DELETE /v1/account/email", s.authed(s.removeEmail))
	mux.HandleFunc("GET /v1/accounts/by-username/{u}", s.authed(s.lookupUsername))
	mux.HandleFunc("GET /u/{u}", s.usernamePage)
}

// GET /v1/verification/methods: cómo se puede entrar (la app enseña la opción de correo solo si está).
func (s *Server) verificationMethods(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"sms": true, "email": s.Mail != nil})
}

func (s *Server) mailOff(w http.ResponseWriter) bool {
	if s.Mail == nil {
		writeErr(w, http.StatusServiceUnavailable, "email_disabled", "entrar con correo aún no está disponible")
		return true
	}
	return false
}

func mailErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInvalidEmail):
		writeErr(w, http.StatusBadRequest, "invalid_email", "ese correo no es válido")
	case errors.Is(err, auth.ErrTooSoon):
		writeErr(w, http.StatusTooManyRequests, "too_soon", "espera un minuto para pedir otro código")
	default:
		slog.Error("enviando correo", "err", err)
		writeErr(w, http.StatusBadGateway, "email_failed", "no se pudo enviar el correo; inténtalo otra vez")
	}
}

// ---------- Entrar con correo ----------

// POST /v1/verification/email/request {email}
func (s *Server) requestEmailCode(w http.ResponseWriter, r *http.Request) {
	if s.mailOff(w) {
		return
	}
	var req struct {
		Email string `json:"email"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	email := auth.NormalizeEmail(req.Email)
	if !auth.ValidEmail(email) {
		writeErr(w, http.StatusBadRequest, "invalid_email", "ese correo no es válido")
		return
	}
	if banned, err := s.store.PhoneBanned(r.Context(), auth.MailIdentity(email)); err == nil && banned {
		writeErr(w, http.StatusForbidden, "banned", "esta cuenta está bloqueada por incumplir las normas de KLK")
		return
	}
	if !s.mailQuota.take("ip:"+s.clientIP(r), 1, maxMailPerIPDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has pedido demasiados códigos hoy; prueba mañana")
		return
	}
	if err := s.Mail.Request("login", email); err != nil {
		mailErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /v1/verification/email/verify {email, code, regToken?, pin?, deviceName, registrationId, identityKey}
// Si el correo ya está en una cuenta (también una de número), entras en esa cuenta.
// Si no, se crea una cuenta nueva con ese correo.
func (s *Server) verifyEmail(w http.ResponseWriter, r *http.Request) {
	if s.mailOff(w) {
		return
	}
	var req struct {
		Email          string `json:"email"`
		Code           string `json:"code"`
		RegToken       string `json:"regToken"`
		Pin            string `json:"pin"`
		DeviceName     string `json:"deviceName"`
		RegistrationID int    `json:"registrationId"`
		IdentityKey    []byte `json:"identityKey"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	email := auth.NormalizeEmail(req.Email)
	if !validPublicKey(req.IdentityKey) || req.RegistrationID <= 0 || req.RegistrationID > 16380 {
		writeErr(w, http.StatusBadRequest, "bad_keys", "identityKey o registrationId inválidos")
		return
	}
	identity := auth.MailIdentity(email)
	_, linked, err := s.store.AccountByEmail(r.Context(), email)
	switch {
	case err == nil:
		identity = linked // la cuenta que ya tiene ese correo (de número o de correo)
	case !errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if req.RegToken != "" {
		if !s.regs.valid(req.RegToken, identity) {
			writeErr(w, http.StatusForbidden, "bad_code", "el código caducó: pide otro")
			return
		}
	} else if err := s.Mail.Verify("login", email, req.Code); err != nil {
		writeErr(w, http.StatusForbidden, "bad_code", "código incorrecto o caducado")
		return
	}
	s.register(w, r, identity, regRequest{Pin: req.Pin, RegToken: req.RegToken, DeviceName: req.DeviceName,
		RegistrationID: req.RegistrationID, IdentityKey: req.IdentityKey}, func(acc string) error {
		if linked != "" {
			return nil
		}
		return s.store.SetEmail(r.Context(), acc, email) // cuenta nueva de correo
	})
}

// ---------- Mi cuenta: @usuario y correo ----------

// GET /v1/account/me
func (s *Server) accountMe(w http.ResponseWriter, r *http.Request) {
	acc := deviceFrom(r).AccountID
	u, err1 := s.store.Username(r.Context(), acc)
	e, err2 := s.store.Email(r.Context(), acc)
	if err1 != nil || err2 != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"username": u, "email": e, "emailLogin": s.Mail != nil})
}

// PUT /v1/account/username {username} ("" = quitarlo)
func (s *Server) setUsername(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	u := NormalizeUsername(req.Username)
	if u != "" && !validUsername(u) {
		writeErr(w, http.StatusBadRequest, "bad_username",
			"usa de 3 a 20 letras sin acentos, números, punto o guion bajo (y que no empiece por «klk»)")
		return
	}
	err := s.store.SetUsername(r.Context(), deviceFrom(r).AccountID, u)
	switch {
	case errors.Is(err, store.ErrTaken):
		writeErr(w, http.StatusConflict, "taken", "ese nombre de usuario ya lo tiene otra persona")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
	default:
		writeJSON(w, http.StatusOK, map[string]string{"username": u})
	}
}

// POST /v1/account/email/request {email}: código para añadir el correo a mi cuenta.
func (s *Server) requestLinkEmail(w http.ResponseWriter, r *http.Request) {
	if s.mailOff(w) {
		return
	}
	var req struct {
		Email string `json:"email"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	email := auth.NormalizeEmail(req.Email)
	if !auth.ValidEmail(email) {
		writeErr(w, http.StatusBadRequest, "invalid_email", "ese correo no es válido")
		return
	}
	acc := deviceFrom(r).AccountID
	if other, _, err := s.store.AccountByEmail(r.Context(), email); err == nil && other != acc {
		writeErr(w, http.StatusConflict, "taken", "ese correo ya está en otra cuenta de KLK")
		return
	}
	if !s.mailQuota.take("acc:"+acc, 1, maxMailPerAccDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has pedido demasiados códigos hoy; prueba mañana")
		return
	}
	if err := s.Mail.Request("link:"+acc, email); err != nil {
		mailErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /v1/account/email/verify {email, code}
func (s *Server) verifyLinkEmail(w http.ResponseWriter, r *http.Request) {
	if s.mailOff(w) {
		return
	}
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	acc := deviceFrom(r).AccountID
	email := auth.NormalizeEmail(req.Email)
	if err := s.Mail.Verify("link:"+acc, email, req.Code); err != nil {
		writeErr(w, http.StatusForbidden, "bad_code", "código incorrecto o caducado")
		return
	}
	err := s.store.SetEmail(r.Context(), acc, email)
	switch {
	case errors.Is(err, store.ErrTaken):
		writeErr(w, http.StatusConflict, "taken", "ese correo ya está en otra cuenta de KLK")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
	default:
		writeJSON(w, http.StatusOK, map[string]string{"email": email})
	}
}

// DELETE /v1/account/email: quitar el correo. Una cuenta creada con correo no
// puede quitarlo (es su forma de entrar).
func (s *Server) removeEmail(w http.ResponseWriter, r *http.Request) {
	acc := deviceFrom(r).AccountID
	e, err := s.store.Email(r.Context(), acc)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if e != "" {
		if _, identity, err := s.store.AccountByEmail(r.Context(), e); err == nil && auth.IsMailIdentity(identity) {
			writeErr(w, http.StatusBadRequest, "email_login", "entras a KLK con este correo: no se puede quitar")
			return
		}
	}
	if err := s.store.SetEmail(r.Context(), acc, ""); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/accounts/by-username/{u}: buscar a alguien por su @.
func (s *Server) lookupUsername(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if !s.lookupQuota.take(dev.AccountID, 1, maxLookupsPerDay, time.Now()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "demasiadas búsquedas hoy")
		return
	}
	u := NormalizeUsername(r.PathValue("u"))
	if !usernameRe.MatchString(u) {
		writeErr(w, http.StatusNotFound, "not_found", "no hay nadie con ese usuario")
		return
	}
	id, err := s.store.AccountByUsername(r.Context(), u)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no hay nadie con ese usuario")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"accountId": id, "username": u})
}

// Página que se abre al escanear el QR de alguien que entró con correo (o al
// tocar su enlace): dice cómo encontrarle en KLK.
var usernameTmpl = template.Must(template.New("u").Parse(`<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>@{{.U}} en KLK messenger</title>
<style>
:root{--navy:#002D62;--red:#C62D35}
*{box-sizing:border-box}body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--navy);color:#fff;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:#fff;color:#111827;border-radius:24px;max-width:380px;width:100%;padding:28px 22px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.3)}
.bubble{display:inline-block;background:var(--red);color:#fff;font-weight:900;font-style:italic;font-size:34px;padding:6px 22px;border-radius:18px;border:4px solid #fff;box-shadow:0 0 0 2px var(--red);transform:rotate(-5deg)}
h1{font-size:24px;margin:18px 0 4px;word-break:break-all}p{color:#4B5563;margin:6px 0 18px}
a.btn{display:block;text-decoration:none;font-weight:700;border-radius:999px;padding:13px;margin:10px 0}
a.p{background:var(--navy);color:#fff}a.s{border:2px solid var(--navy);color:var(--navy)}
</style></head><body><div class="card">
<div class="bubble">¡Klk!</div>
<h1>@{{.U}}</h1>
<p>Te espera en KLK messenger. Abre KLK, toca <b>+ → Nuevo chat</b> y busca <b>@{{.U}}</b>.</p>
<a class="btn p" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/download/android/KLK-messenger.apk">Descargar para Android</a>
<a class="btn s" href="https://github.com/emmanuelmartinezgirlanda-hub/KLK-messenger-/releases/latest">Descargar para Windows</a>
</div></body></html>`))

func (s *Server) usernamePage(w http.ResponseWriter, r *http.Request) {
	u := NormalizeUsername(r.PathValue("u"))
	if !usernameRe.MatchString(u) {
		http.NotFound(w, r)
		return
	}
	if _, err := s.store.AccountByUsername(r.Context(), u); err != nil {
		http.NotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'")
	usernameTmpl.Execute(w, map[string]string{"U": u})
}
