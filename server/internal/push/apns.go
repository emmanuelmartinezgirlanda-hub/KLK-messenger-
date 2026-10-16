// Package push avisa a los iPhone desconectados de que tienen mensajes nuevos,
// mediante el servicio de notificaciones de Apple (APNs).
//
// La notificación NO lleva el mensaje ni quién lo envía (los mensajes van
// cifrados de punta a punta y el servidor no puede leerlos): solo
// "Tienes un mensaje nuevo". Al abrir KLK, el mensaje se descarga y se descifra.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	ProductionHost = "https://api.push.apple.com"
	SandboxHost    = "https://api.sandbox.push.apple.com"

	// Apple pide renovar el JWT entre 20 y 60 minutos.
	jwtLifetime = 40 * time.Minute
	// Como mucho una notificación por dispositivo en este intervalo
	// (si llegan 20 mensajes seguidos, suena una vez).
	minInterval = 3 * time.Second
	sendTimeout = 15 * time.Second
)

// TokenStore es lo que el emisor necesita del almacén.
type TokenStore interface {
	PushToken(ctx context.Context, accountID string, deviceID int) (string, error)
	DropPushToken(ctx context.Context, token string) error
}

// Config son los datos de la clave de notificaciones de Apple Developer.
type Config struct {
	KeyPEM string // contenido del archivo AuthKey_XXXX.p8
	KeyID  string // los 10 caracteres del nombre de la clave
	TeamID string // Team ID de la cuenta de desarrollador
	Topic  string // bundle id de la app (com.klkapp.klk)
	Host   string // ProductionHost (TestFlight y App Store) o SandboxHost
	Title  string // título de la notificación
	Body   string // texto de la notificación
}

type APNs struct {
	cfg    Config
	key    *ecdsa.PrivateKey
	store  TokenStore
	client *http.Client
	now    func() time.Time

	mu     sync.Mutex
	jwt    string
	jwtAt  time.Time
	recent map[string]time.Time // token -> último aviso
}

// New prepara el emisor. Devuelve error si la clave no es válida.
func New(cfg Config, store TokenStore) (*APNs, error) {
	key, err := ParseKey(cfg.KeyPEM)
	if err != nil {
		return nil, err
	}
	if len(cfg.KeyID) == 0 || len(cfg.TeamID) == 0 || cfg.Topic == "" {
		return nil, errors.New("faltan APNS_KEY_ID, APNS_TEAM_ID o APNS_TOPIC")
	}
	if cfg.Host == "" {
		cfg.Host = ProductionHost
	}
	if cfg.Title == "" {
		cfg.Title = "KLK messenger"
	}
	if cfg.Body == "" {
		cfg.Body = "Tienes un mensaje nuevo"
	}
	// http.Client usa HTTP/2 con TLS automáticamente (APNs lo exige).
	return &APNs{cfg: cfg, key: key, store: store, client: &http.Client{Timeout: sendTimeout},
		now: time.Now, recent: map[string]time.Time{}}, nil
}

// ParseKey lee la clave .p8. Acepta el PEM tal cual, con "\n" escritos como
// texto (paneles que no admiten varias líneas) o solo el bloque en base64.
func ParseKey(s string) (*ecdsa.PrivateKey, error) {
	s = strings.TrimSpace(strings.ReplaceAll(s, `\n`, "\n"))
	if s == "" {
		return nil, errors.New("APNS_KEY vacía")
	}
	if !strings.Contains(s, "BEGIN") {
		s = "-----BEGIN PRIVATE KEY-----\n" + strings.Join(strings.Fields(s), "") + "\n-----END PRIVATE KEY-----"
	}
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("APNS_KEY no es un archivo .p8 válido")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("APNS_KEY: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNS_KEY no es una clave de notificaciones de Apple (ES256)")
	}
	return ec, nil
}

// Notify avisa a un dispositivo desconectado. No bloquea: el envío va aparte.
func (a *APNs) Notify(_ context.Context, accountID string, deviceID int) {
	go a.send(accountID, deviceID)
}

func (a *APNs) send(accountID string, deviceID int) {
	ctx, cancel := context.WithTimeout(context.Background(), sendTimeout)
	defer cancel()
	token, err := a.store.PushToken(ctx, accountID, deviceID)
	if err != nil || token == "" {
		return
	}
	if !a.allow(token) {
		return
	}
	status, reason, err := a.post(ctx, token)
	switch {
	case err != nil:
		slog.Warn("push", "err", err)
	case status == http.StatusOK:
	case status == http.StatusGone || reason == "BadDeviceToken" || reason == "Unregistered" || reason == "DeviceTokenNotForTopic":
		// El iPhone ya no acepta avisos (app borrada, token viejo…).
		_ = a.store.DropPushToken(ctx, token)
	default:
		slog.Warn("push rechazado por Apple", "status", status, "reason", reason)
	}
}

// allow limita a un aviso por dispositivo cada [minInterval].
func (a *APNs) allow(token string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if last, ok := a.recent[token]; ok && now.Sub(last) < minInterval {
		return false
	}
	a.recent[token] = now
	if len(a.recent) > 10000 { // limpieza de vez en cuando
		for t, at := range a.recent {
			if now.Sub(at) > time.Minute {
				delete(a.recent, t)
			}
		}
	}
	return true
}

type payload struct {
	APS aps `json:"aps"`
}

type aps struct {
	Alert    alert  `json:"alert"`
	Sound    string `json:"sound"`
	ThreadID string `json:"thread-id"`
}

type alert struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

func (a *APNs) post(ctx context.Context, token string) (int, string, error) {
	jwt, err := a.token()
	if err != nil {
		return 0, "", err
	}
	body, _ := json.Marshal(payload{APS: aps{
		Alert: alert{Title: a.cfg.Title, Body: a.cfg.Body}, Sound: "default", ThreadID: "klk"}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.Host+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", a.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	// Los avisos se agrupan: si hay varios sin ver, el iPhone muestra uno.
	req.Header.Set("apns-collapse-id", "klk-nuevo-mensaje")
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	var r struct {
		Reason string `json:"reason"`
	}
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	_ = json.Unmarshal(data, &r)
	return resp.StatusCode, r.Reason, nil
}

// token devuelve el JWT de autenticación con Apple (ES256), renovándolo si toca.
func (a *APNs) token() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if a.jwt != "" && now.Sub(a.jwtAt) < jwtLifetime {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.cfg.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": a.cfg.TeamID, "iat": now.Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, sum[:])
	if err != nil {
		return "", err
	}
	// ES256: r y s de 32 bytes cada uno, seguidos.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt = signing + "." + enc.EncodeToString(sig)
	a.jwtAt = now
	return a.jwt, nil
}
