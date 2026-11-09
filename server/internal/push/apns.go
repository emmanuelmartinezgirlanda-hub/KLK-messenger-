// Package push manda avisos a los móviles (APNs de Apple) cuando llega un
// mensaje y la app está cerrada. El aviso NUNCA lleva el mensaje ni quién lo
// manda: solo "Tienes un mensaje nuevo". El contenido sigue cifrado de punta a
// punta y la app lo descarga al abrirse.
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
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// Config de APNs (se saca de la cuenta de Apple Developer → Keys).
type Config struct {
	KeyPEM  string // contenido del archivo .p8
	KeyID   string // "Key ID" de 10 caracteres
	TeamID  string // "Team ID" de 10 caracteres
	Topic   string // bundle id de la app, p. ej. com.klkapp.klk
	Sandbox bool   // true solo para apps compiladas desde Xcode en modo desarrollo
}

// APNs envía avisos a iPhone.
type APNs struct {
	cfg    Config
	key    *ecdsa.PrivateKey
	tokens store.PushStore
	client *http.Client
	host   string
	now    func() time.Time

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
	last  map[string]time.Time // último aviso por token (para no saturar)
}

// minGap: como mucho un aviso cada pocos segundos por móvil (los avisos
// seguidos se agrupan igualmente en uno con apns-collapse-id).
const minGap = 3 * time.Second

// NewAPNs prepara el envío. Devuelve error si la clave .p8 no es válida.
func NewAPNs(cfg Config, tokens store.PushStore) (*APNs, error) {
	key, err := parseP8(cfg.KeyPEM)
	if err != nil {
		return nil, err
	}
	if cfg.KeyID == "" || cfg.TeamID == "" || cfg.Topic == "" {
		return nil, errors.New("faltan Key ID, Team ID o bundle id")
	}
	host := "https://api.push.apple.com"
	if cfg.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	return &APNs{
		cfg: cfg, key: key, tokens: tokens, host: host, now: time.Now,
		client: &http.Client{Timeout: 15 * time.Second},
		last:   map[string]time.Time{},
	}, nil
}

func parseP8(s string) (*ecdsa.PrivateKey, error) {
	// Render y otros paneles a veces convierten los saltos de línea en espacios
	// o en «\n» literales. Quitamos cabeceras y espacios y lo rearmamos.
	s = strings.ReplaceAll(s, `\n`, "\n")
	s = strings.Trim(s, " \t\r\n\"'")
	for _, h := range []string{"-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"} {
		s = strings.ReplaceAll(s, h, "")
	}
	s = strings.Join(strings.Fields(s), "")
	s = "-----BEGIN PRIVATE KEY-----\n" + s + "\n-----END PRIVATE KEY-----\n"
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("la clave .p8 no tiene formato PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("clave .p8 inválida: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("la clave .p8 no es de tipo EC")
	}
	return ec, nil
}

// Notify avisa (en segundo plano) al dispositivo, si tiene token.
func (a *APNs) Notify(_ context.Context, accountID string, deviceID int) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		t, err := a.tokens.GetPushToken(ctx, accountID, deviceID)
		if err != nil || t.Platform != "apns" || t.Token == "" {
			return
		}
		if !a.allow(t.Token) {
			return
		}
		gone, err := a.send(ctx, t.Token, Text(t.Lang))
		if gone {
			_ = a.tokens.DeletePushToken(ctx, accountID, deviceID)
			return
		}
		if err != nil {
			slog.Warn("aviso push", "err", err)
		}
	}()
}

func (a *APNs) allow(token string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if t, ok := a.last[token]; ok && now.Sub(t) < minGap {
		return false
	}
	a.last[token] = now
	if len(a.last) > 50000 { // limpieza sencilla
		for k, t := range a.last {
			if now.Sub(t) > time.Minute {
				delete(a.last, k)
			}
		}
	}
	return true
}

// Text es el aviso en el idioma del móvil. Nunca incluye el mensaje.
func Text(lang string) string {
	switch strings.ToLower(lang) {
	case "en":
		return "You have a new message"
	case "it":
		return "Hai un nuovo messaggio"
	case "fr":
		return "Vous avez un nouveau message"
	case "pt":
		return "Você tem uma nova mensagem"
	default:
		return "Tienes un mensaje nuevo"
	}
}

// send devuelve gone=true si Apple dice que el token ya no vale (app borrada…).
func (a *APNs) send(ctx context.Context, token, text string) (gone bool, err error) {
	body, _ := json.Marshal(map[string]any{
		"aps": map[string]any{
			"alert":     map[string]string{"title": "KLK messenger", "body": text},
			"sound":     "default",
			"thread-id": "klk",
		},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.host+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	jwt, err := a.bearer()
	if err != nil {
		return false, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", a.cfg.Topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-collapse-id", "klk-new")
	req.Header.Set("apns-expiration", fmt.Sprint(a.now().Add(24*time.Hour).Unix()))
	res, err := a.client.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return false, nil
	}
	var why struct {
		Reason string `json:"reason"`
	}
	b, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
	_ = json.Unmarshal(b, &why)
	switch {
	case res.StatusCode == http.StatusGone,
		why.Reason == "BadDeviceToken", why.Reason == "DeviceTokenNotForTopic", why.Reason == "Unregistered":
		return true, nil
	case why.Reason == "ExpiredProviderToken" || why.Reason == "InvalidProviderToken":
		a.mu.Lock()
		a.jwt = ""
		a.mu.Unlock()
	}
	return false, fmt.Errorf("APNs %d %s", res.StatusCode, why.Reason)
}

// bearer devuelve el JWT de proveedor (ES256). Apple pide renovarlo entre 20 y 60 min.
func (a *APNs) bearer() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if a.jwt != "" && now.Sub(a.jwtAt) < 40*time.Minute {
		return a.jwt, nil
	}
	tok, err := signJWT(a.key, a.cfg.KeyID, a.cfg.TeamID, now)
	if err != nil {
		return "", err
	}
	a.jwt, a.jwtAt = tok, now
	return tok, nil
}

func signJWT(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
	c, _ := json.Marshal(map[string]any{"iss": teamID, "iat": now.Unix()})
	unsigned := enc.EncodeToString(h) + "." + enc.EncodeToString(c)
	sum := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return unsigned + "." + enc.EncodeToString(sig), nil
}

// verifyJWT solo se usa en los tests.
func verifyJWT(pub *ecdsa.PublicKey, tok string) bool {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return ecdsa.Verify(pub, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}
