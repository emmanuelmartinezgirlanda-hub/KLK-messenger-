// Package api expone la API HTTP de KLK.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
	"golang.org/x/time/rate"

	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
)

const maxPreKeysPerUpload = 200

type Server struct {
	store store.Store
	otp   *auth.OTP
	hub   *relay.Hub

	ipLimits    sync.Map // ip -> *rate.Limiter
	adminLimits sync.Map // ip -> *rate.Limiter (panel)
	touched  sync.Map // accountID -> time.Time (última vez que se apuntó last_seen)

	// AdminToken abre el panel del dueño (/admin). Vacío = panel desactivado.
	AdminToken string
	// Precios para calcular gastos en el panel (en euros).
	SMSPrice   float64
	ServerCost float64

	// TrustProxy usa X-Forwarded-For para identificar la IP del cliente.
	// Actívalo solo detrás de un proxy de confianza (Render, Cloudflare…).
	TrustProxy bool
}

func New(s store.Store, otp *auth.OTP, hub *relay.Hub) *Server {
	return &Server{store: s, otp: otp, hub: hub}
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })

	mux.HandleFunc("POST /v1/verification/request", s.limited(s.requestCode))
	mux.HandleFunc("POST /v1/verification/verify", s.limited(s.verify))

	mux.HandleFunc("PUT /v1/keys", s.authed(s.putKeys))
	mux.HandleFunc("GET /v1/keys/count", s.authed(s.keyCount))
	mux.HandleFunc("GET /v1/keys/{accountId}", s.authed(s.getBundles))
	mux.HandleFunc("POST /v1/accounts/lookup", s.limited(s.authed(s.lookup)))
	mux.HandleFunc("POST /v1/accounts/lookup-batch", s.limited(s.authed(s.lookupBatch)))

	mux.HandleFunc("POST /v1/attachments", s.authed(s.uploadAttachment))
	mux.HandleFunc("GET /v1/attachments/{id}", s.authed(s.downloadAttachment))

	mux.HandleFunc("POST /v1/reports", s.authed(s.report))
	mux.HandleFunc("GET /v1/announcements", s.authed(s.announcements))

	mux.HandleFunc("GET /v1/communities", s.authed(s.listCommunities))
	mux.HandleFunc("POST /v1/communities/{id}", s.authed(s.joinCommunity))
	mux.HandleFunc("DELETE /v1/communities/{id}", s.authed(s.joinCommunity))
	mux.HandleFunc("GET /v1/communities/{id}/members", s.authed(s.communityMembers))

	s.adminRoutes(mux)

	mux.HandleFunc("GET /v1/ws", s.authed(s.websocket))
	return mux
}

// ---------- Middleware ----------

type ctxKey struct{}

func deviceFrom(r *http.Request) store.Device { return r.Context().Value(ctxKey{}).(store.Device) }

// authed exige "Authorization: Bearer <token>".
func (s *Server) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || tok == "" {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "falta el token")
			return
		}
		dev, err := s.store.DeviceByTokenHash(r.Context(), auth.HashToken(tok))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "token inválido")
			return
		}
		if dev.Banned {
			writeErr(w, http.StatusForbidden, "banned", "esta cuenta está bloqueada por incumplir las normas de KLK")
			return
		}
		s.touch(r.Context(), dev.AccountID)
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, dev)))
	}
}

// limited aplica un límite por IP a rutas sensibles (SMS, búsqueda de números).
func (s *Server) limited(next http.HandlerFunc) http.HandlerFunc {
	return s.limitWith(&s.ipLimits, rate.Every(6*time.Second), 10, next)
}

// limitedN es un límite más amplio para el panel (varias peticiones por pantalla),
// que sigue frenando a quien intente adivinar la clave.
func (s *Server) limitedN(next http.HandlerFunc) http.HandlerFunc {
	return s.limitWith(&s.adminLimits, rate.Every(time.Second), 30, next)
}

func (s *Server) limitWith(m *sync.Map, every rate.Limit, burst int, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		if s.TrustProxy {
			// El proxy añade la IP real al final de la lista.
			if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
				parts := strings.Split(xff, ",")
				ip = strings.TrimSpace(parts[len(parts)-1])
			}
		}
		l, _ := m.LoadOrStore(ip, rate.NewLimiter(every, burst))
		if !l.(*rate.Limiter).Allow() {
			writeErr(w, http.StatusTooManyRequests, "rate_limited", "demasiadas peticiones, prueba en un momento")
			return
		}
		next(w, r)
	}
}

// ---------- Registro ----------

func (s *Server) requestCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone string `json:"phone"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if banned, err := s.store.PhoneBanned(r.Context(), req.Phone); err == nil && banned {
		writeErr(w, http.StatusForbidden, "banned", "este número está bloqueado por incumplir las normas de KLK")
		return
	}
	switch err := s.otp.Request(req.Phone); {
	case errors.Is(err, auth.ErrInvalidPhone):
		writeErr(w, http.StatusBadRequest, "invalid_phone", err.Error())
	case errors.Is(err, auth.ErrTooSoon):
		writeErr(w, http.StatusTooManyRequests, "too_soon", err.Error())
	case err != nil:
		slog.Error("enviando SMS", "err", err)
		writeErr(w, http.StatusBadGateway, "sms_failed", "no se pudo enviar el SMS")
	default:
		if err := s.store.LogSMS(r.Context(), store.CountryOf(req.Phone), time.Now()); err != nil {
			slog.Warn("contando SMS", "err", err)
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) verify(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone          string `json:"phone"`
		Code           string `json:"code"`
		DeviceName     string `json:"deviceName"`
		RegistrationID int    `json:"registrationId"`
		IdentityKey    []byte `json:"identityKey"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !validPublicKey(req.IdentityKey) || req.RegistrationID <= 0 || req.RegistrationID > 16380 {
		writeErr(w, http.StatusBadRequest, "bad_keys", "identityKey o registrationId inválidos")
		return
	}
	if err := s.otp.Verify(req.Phone, req.Code); err != nil {
		writeErr(w, http.StatusForbidden, "bad_code", err.Error())
		return
	}
	if banned, err := s.store.PhoneBanned(r.Context(), req.Phone); err == nil && banned {
		writeErr(w, http.StatusForbidden, "banned", "este número está bloqueado por incumplir las normas de KLK")
		return
	}
	token, hash, err := auth.NewToken()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	dev, err := s.store.RegisterPrimary(r.Context(), store.RegisterParams{
		Phone: req.Phone, DeviceName: truncate(req.DeviceName, 64),
		RegistrationID: req.RegistrationID, IdentityKey: req.IdentityKey, TokenHash: hash,
	})
	if err != nil {
		slog.Error("registro", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	s.touch(r.Context(), dev.AccountID)
	writeJSON(w, http.StatusOK, map[string]any{
		"accountId": dev.AccountID, "deviceId": dev.DeviceID, "token": token,
	})
}

// ---------- Claves ----------

func (s *Server) putKeys(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		SignedPreKey *store.SignedPreKey `json:"signedPreKey"`
		PreKeys      []store.PreKey      `json:"preKeys"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if len(req.PreKeys) > maxPreKeysPerUpload {
		writeErr(w, http.StatusBadRequest, "too_many", "máximo 200 prekeys por petición")
		return
	}
	if req.SignedPreKey != nil {
		// La firma la verifica el remitente con libsignal al iniciar sesión.
		if !validPublicKey(req.SignedPreKey.PublicKey) || len(req.SignedPreKey.Signature) != 64 {
			writeErr(w, http.StatusBadRequest, "bad_keys", "signedPreKey inválida")
			return
		}
		if err := s.store.SetSignedPreKey(r.Context(), dev.AccountID, dev.DeviceID, *req.SignedPreKey); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "error interno")
			return
		}
	}
	for _, k := range req.PreKeys {
		if !validPublicKey(k.PublicKey) {
			writeErr(w, http.StatusBadRequest, "bad_keys", "prekey inválida")
			return
		}
	}
	if len(req.PreKeys) > 0 {
		if err := s.store.AddPreKeys(r.Context(), dev.AccountID, dev.DeviceID, req.PreKeys); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "error interno")
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) keyCount(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	n, err := s.store.PreKeyCount(r.Context(), dev.AccountID, dev.DeviceID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"count": n})
}

func (s *Server) getBundles(w http.ResponseWriter, r *http.Request) {
	bundles, err := s.store.TakeBundles(r.Context(), r.PathValue("accountId"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "cuenta sin claves publicadas")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": bundles})
}

// lookup traduce un número a accountId para poder escribirle.
// Aviso de privacidad: revela si un número usa KLK. Por eso va limitado por IP
// y requiere sesión. Para escalar, ver "descubrimiento privado de contactos" en el README.
func (s *Server) lookup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone string `json:"phone"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	id, err := s.store.AccountIDByPhone(r.Context(), req.Phone)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "ese número no usa KLK todavía")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"accountId": id})
}

// MaxLookupBatch limita cuántos números se comprueban por petición.
const MaxLookupBatch = 1000

// lookupBatch comprueba qué contactos de la agenda usan KLK.
// Solo devuelve los que existen; el resto de números no se guarda.
func (s *Server) lookupBatch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phones []string `json:"phones"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if len(req.Phones) > MaxLookupBatch {
		writeErr(w, http.StatusBadRequest, "too_many", "máximo 1000 números por petición")
		return
	}
	valid := make([]string, 0, len(req.Phones))
	for _, p := range req.Phones {
		if auth.ValidPhone(p) {
			valid = append(valid, p)
		}
	}
	found, err := s.store.AccountIDsByPhones(r.Context(), valid)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"found": found})
}

// ---------- Adjuntos ----------

// MaxAttachmentBytes limita el tamaño de cada archivo cifrado (fotos, vídeos, audios…).
const MaxAttachmentBytes = 64 << 20 // 64 MB

// ---------- Denuncias ----------

const (
	maxReportsPerDay    = 20
	maxReportMessages   = 5
	maxReportMessageLen = 2000
)

var reportReasons = map[string]bool{"spam": true, "acoso": true, "estafa": true, "otro": true}

// report guarda una denuncia. Los mensajes están cifrados de punta a punta, así
// que solo llegan aquí los que el usuario decide adjuntar.
func (s *Server) report(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	var req struct {
		AccountID string   `json:"accountId"`
		Reason    string   `json:"reason"`
		Messages  []string `json:"messages"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !reportReasons[req.Reason] {
		writeErr(w, http.StatusBadRequest, "bad_reason", "motivo no válido")
		return
	}
	if req.AccountID == dev.AccountID {
		writeErr(w, http.StatusBadRequest, "self", "no puedes denunciarte a ti mismo")
		return
	}
	if len(req.Messages) > maxReportMessages {
		req.Messages = req.Messages[len(req.Messages)-maxReportMessages:]
	}
	for i, m := range req.Messages {
		req.Messages[i] = truncate(m, maxReportMessageLen)
	}
	ok, err := s.store.AccountExists(r.Context(), req.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "esa cuenta no existe")
		return
	}
	n, err := s.store.ReportsBy(r.Context(), dev.AccountID, time.Now().Add(-24*time.Hour))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if n >= maxReportsPerDay {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "has enviado demasiadas denuncias hoy")
		return
	}
	rep := store.Report{
		ID: uuid.NewString(), Reporter: dev.AccountID, Reported: req.AccountID,
		Reason: req.Reason, Messages: req.Messages, CreatedAt: time.Now(),
	}
	if err := s.store.AddReport(r.Context(), rep); err != nil {
		slog.Error("denuncia", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	slog.Info("denuncia recibida", "reason", req.Reason, "messages", len(req.Messages))
	writeJSON(w, http.StatusCreated, map[string]string{"id": rep.ID})
}

// uploadAttachment recibe un archivo YA CIFRADO en el móvil (cuerpo binario).
// La clave para descifrarlo viaja dentro del mensaje cifrado, nunca aquí.
func (s *Server) uploadAttachment(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if r.ContentLength > MaxAttachmentBytes {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "el archivo supera los 64 MB")
		return
	}
	body := http.MaxBytesReader(w, r.Body, MaxAttachmentBytes)
	data, err := io.ReadAll(body)
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "el archivo supera los 64 MB")
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_body", "no se pudo leer el archivo")
		return
	}
	if len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "empty", "el archivo está vacío")
		return
	}
	id := uuid.NewString()
	if err := s.store.PutAttachment(r.Context(), id, dev.AccountID, data); err != nil {
		slog.Error("adjunto", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) downloadAttachment(w http.ResponseWriter, r *http.Request) {
	data, err := s.store.GetAttachment(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "el archivo no existe o ya caducó")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Write(data)
}

// ---------- WebSocket ----------

func (s *Server) websocket(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	s.hub.Serve(context.WithoutCancel(r.Context()), conn, dev)
}

// ---------- Utilidades ----------

// Las claves públicas de Signal (Curve25519) miden 33 bytes y empiezan por 0x05.
func validPublicKey(k []byte) bool { return len(k) == 33 && k[0] == 0x05 }

func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "JSON inválido")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"code": code, "message": msg})
}

func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
