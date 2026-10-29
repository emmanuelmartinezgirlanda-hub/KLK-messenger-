package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
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
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// FCM envía avisos a Android con Firebase Cloud Messaging (API HTTP v1).
// Igual que en iPhone, el aviso solo dice «Tienes un mensaje nuevo».
type FCM struct {
	projectID string
	email     string
	key       *rsa.PrivateKey
	tokenURL  string
	sendURL   string // https://fcm.googleapis.com/v1/projects/<id>/messages:send
	tokens    store.PushStore
	client    *http.Client
	now       func() time.Time

	mu        sync.Mutex
	access    string
	accessExp time.Time
	last      map[string]time.Time
}

// ServiceAccount es lo que interesa del .json de «Cuentas de servicio» de Firebase.
type ServiceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// ParseServiceAccount acepta el .json tal cual, pegado en una línea o en base64.
func ParseServiceAccount(s string) (ServiceAccount, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "{") {
		if b, err := base64.StdEncoding.DecodeString(s); err == nil {
			s = strings.TrimSpace(string(b))
		}
	}
	var sa ServiceAccount
	if err := json.Unmarshal([]byte(s), &sa); err != nil {
		return sa, errors.New("la clave de Firebase no es un .json válido")
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return sa, errors.New("a la clave de Firebase le faltan project_id, client_email o private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return sa, nil
}

// NewFCM prepara el envío a Android a partir de la cuenta de servicio.
func NewFCM(credentials string, tokens store.PushStore) (*FCM, error) {
	sa, err := ParseServiceAccount(credentials)
	if err != nil {
		return nil, err
	}
	key, err := parseRSA(sa.PrivateKey)
	if err != nil {
		return nil, err
	}
	return &FCM{
		projectID: sa.ProjectID,
		email:     sa.ClientEmail,
		key:       key,
		tokenURL:  sa.TokenURI,
		sendURL:   "https://fcm.googleapis.com/v1/projects/" + url.PathEscape(sa.ProjectID) + "/messages:send",
		tokens:    tokens,
		client:    &http.Client{Timeout: 15 * time.Second},
		now:       time.Now,
		last:      map[string]time.Time{},
	}, nil
}

// ProjectID del proyecto de Firebase (para el panel).
func (f *FCM) ProjectID() string { return f.projectID }

func parseRSA(s string) (*rsa.PrivateKey, error) {
	s = strings.ReplaceAll(s, `\n`, "\n")
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("la clave privada de Firebase no tiene formato PEM")
	}
	if k, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if rk, ok := k.(*rsa.PrivateKey); ok {
			return rk, nil
		}
		return nil, errors.New("la clave privada de Firebase no es RSA")
	}
	rk, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("clave privada de Firebase inválida: %w", err)
	}
	return rk, nil
}

// Notify avisa (en segundo plano) al móvil Android, si tiene token.
func (f *FCM) Notify(_ context.Context, accountID string, deviceID int) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		t, err := f.tokens.GetPushToken(ctx, accountID, deviceID)
		if err != nil || t.Platform != "fcm" || t.Token == "" {
			return
		}
		if !f.allow(t.Token) {
			return
		}
		gone, err := f.send(ctx, t.Token, Text(t.Lang))
		if gone {
			_ = f.tokens.DeletePushToken(ctx, accountID, deviceID)
			return
		}
		if err != nil {
			slog.Warn("aviso push Android", "err", err)
		}
	}()
}

func (f *FCM) allow(token string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	now := f.now()
	if t, ok := f.last[token]; ok && now.Sub(t) < minGap {
		return false
	}
	f.last[token] = now
	if len(f.last) > 50000 {
		for k, t := range f.last {
			if now.Sub(t) > time.Minute {
				delete(f.last, k)
			}
		}
	}
	return true
}

// send devuelve gone=true si Firebase dice que el token ya no vale.
func (f *FCM) send(ctx context.Context, token, text string) (gone bool, err error) {
	access, err := f.accessToken(ctx)
	if err != nil {
		return false, err
	}
	body, _ := json.Marshal(map[string]any{
		"message": map[string]any{
			"token":        token,
			"notification": map[string]string{"title": "KLK messenger", "body": text},
			"android": map[string]any{
				"priority":     "HIGH",
				"collapse_key": "klk-new",
				"ttl":          "86400s",
				"notification": map[string]string{
					"channel_id": "klk_messages",
					"tag":        "klk-new",
					"sound":      "default",
				},
			},
		},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.sendURL, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.client.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusOK {
		return false, nil
	}
	b, _ := io.ReadAll(io.LimitReader(res.Body, 8192))
	msg := string(b)
	switch {
	case res.StatusCode == http.StatusNotFound || strings.Contains(msg, "UNREGISTERED"):
		return true, nil
	case res.StatusCode == http.StatusBadRequest && strings.Contains(msg, "registration token"):
		return true, nil
	case res.StatusCode == http.StatusUnauthorized:
		f.mu.Lock()
		f.access = ""
		f.mu.Unlock()
	}
	if len(msg) > 300 {
		msg = msg[:300]
	}
	return false, fmt.Errorf("FCM %d %s", res.StatusCode, msg)
}

// accessToken pide (y guarda ~1 h) el token de Google con la cuenta de servicio.
func (f *FCM) accessToken(ctx context.Context) (string, error) {
	f.mu.Lock()
	if f.access != "" && f.now().Before(f.accessExp) {
		a := f.access
		f.mu.Unlock()
		return a, nil
	}
	f.mu.Unlock()

	assertion, err := f.signAssertion(f.now())
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := f.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 16384)).Decode(&out); err != nil {
		return "", fmt.Errorf("token de Google: %w", err)
	}
	if res.StatusCode != http.StatusOK || out.AccessToken == "" {
		return "", fmt.Errorf("token de Google %d: %s %s", res.StatusCode, out.Error, out.Description)
	}
	if out.ExpiresIn <= 0 {
		out.ExpiresIn = 3600
	}
	f.mu.Lock()
	f.access = out.AccessToken
	f.accessExp = f.now().Add(time.Duration(out.ExpiresIn)*time.Second - 2*time.Minute)
	f.mu.Unlock()
	return out.AccessToken, nil
}

func (f *FCM) signAssertion(now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{
		"iss":   f.email,
		"scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud":   f.tokenURL,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})
	unsigned := enc.EncodeToString(head) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(unsigned))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return unsigned + "." + enc.EncodeToString(sig), nil
}

// Multi reparte cada aviso entre varios servicios (APNs para iPhone y FCM
// para Android); cada uno solo actúa si el token del móvil es suyo.
type Multi []interface {
	Notify(ctx context.Context, accountID string, deviceID int)
}

func (m Multi) Notify(ctx context.Context, accountID string, deviceID int) {
	for _, p := range m {
		p.Notify(ctx, accountID, deviceID)
	}
}
