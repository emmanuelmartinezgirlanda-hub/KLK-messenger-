// Package playstore comprueba las suscripciones de KLK Plus compradas con
// Google Play (Android). La app nos manda el «purchase token» de la compra y
// aquí se lo preguntamos a la Google Play Developer API con una cuenta de
// servicio (la misma de Firebase sirve si se invita en Play Console con
// permiso para ver pedidos y suscripciones).
package playstore

import (
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
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ErrNotFound: Google no conoce ese token (inventado o de otra app).
var ErrNotFound = errors.New("playstore: compra no encontrada")

// Subscription son los datos de una suscripción que nos importan.
type Subscription struct {
	State        string    // SUBSCRIPTION_STATE_ACTIVE, …_IN_GRACE_PERIOD, …_CANCELED, …
	Acknowledged bool      // false = hay que confirmarla en 3 días o Google la devuelve
	ProductID    string    // p. ej. klk.plus.mensual
	Expires      time.Time // fin del periodo pagado
	AccountID    string    // obfuscatedExternalAccountId (la cuenta de KLK que compró)
	Test         bool      // compra de prueba (testers con licencia)
}

// Entitled dice si la suscripción da Plus ahora. Una suscripción cancelada
// sigue valiendo hasta que se acaba el periodo pagado.
func (s Subscription) Entitled(now time.Time) bool {
	switch s.State {
	case "SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "SUBSCRIPTION_STATE_CANCELED":
		return s.Expires.After(now)
	}
	return false
}

// Verifier habla con la Google Play Developer API.
type Verifier struct {
	Package string // com.klkapp.klk

	email    string
	key      *rsa.PrivateKey
	tokenURL string
	baseURL  string // https://androidpublisher.googleapis.com
	client   *http.Client
	now      func() time.Time

	mu        sync.Mutex
	access    string
	accessExp time.Time
}

type serviceAccount struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// New prepara el verificador con el .json de una cuenta de servicio de Google
// (tal cual o en base64).
func New(credentials, pkg string) (*Verifier, error) {
	s := strings.TrimSpace(credentials)
	if !strings.HasPrefix(s, "{") {
		if b, err := base64.StdEncoding.DecodeString(s); err == nil {
			s = strings.TrimSpace(string(b))
		}
	}
	var sa serviceAccount
	if err := json.Unmarshal([]byte(s), &sa); err != nil {
		return nil, errors.New("la clave de Google no es un .json válido")
	}
	if sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("a la clave de Google le faltan client_email o private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	block, _ := pem.Decode([]byte(strings.ReplaceAll(sa.PrivateKey, `\n`, "\n")))
	if block == nil {
		return nil, errors.New("la clave privada de Google no tiene formato PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("clave privada de Google inválida: %w", err)
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("la clave privada de Google no es RSA")
	}
	if pkg == "" {
		pkg = "com.klkapp.klk"
	}
	return &Verifier{
		Package: pkg, email: sa.ClientEmail, key: rk, tokenURL: sa.TokenURI,
		baseURL: "https://androidpublisher.googleapis.com",
		client:  &http.Client{Timeout: 15 * time.Second}, now: time.Now,
	}, nil
}

// Email de la cuenta de servicio (para el panel: es la que hay que invitar en Play Console).
func (v *Verifier) Email() string { return v.email }

// Subscription consulta una compra por su token (API subscriptionsv2).
func (v *Verifier) Subscription(ctx context.Context, token string) (Subscription, error) {
	var out Subscription
	u := v.baseURL + "/androidpublisher/v3/applications/" + url.PathEscape(v.Package) +
		"/purchases/subscriptionsv2/tokens/" + url.PathEscape(token)
	var res struct {
		SubscriptionState    string    `json:"subscriptionState"`
		AcknowledgementState string    `json:"acknowledgementState"`
		TestPurchase         *struct{} `json:"testPurchase"`
		LineItems            []struct {
			ProductID  string `json:"productId"`
			ExpiryTime string `json:"expiryTime"`
		} `json:"lineItems"`
		ExternalAccountIdentifiers struct {
			ObfuscatedExternalAccountID string `json:"obfuscatedExternalAccountId"`
		} `json:"externalAccountIdentifiers"`
	}
	if err := v.call(ctx, http.MethodGet, u, nil, &res); err != nil {
		return out, err
	}
	out.State = res.SubscriptionState
	out.Acknowledged = res.AcknowledgementState == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
	out.AccountID = res.ExternalAccountIdentifiers.ObfuscatedExternalAccountID
	out.Test = res.TestPurchase != nil
	for _, li := range res.LineItems {
		t, err := time.Parse(time.RFC3339Nano, li.ExpiryTime)
		if err != nil {
			continue
		}
		if t.After(out.Expires) {
			out.Expires, out.ProductID = t, li.ProductID
		}
	}
	return out, nil
}

// Acknowledge confirma la compra (si no, Google la devuelve a los 3 días).
func (v *Verifier) Acknowledge(ctx context.Context, productID, token string) error {
	u := v.baseURL + "/androidpublisher/v3/applications/" + url.PathEscape(v.Package) +
		"/purchases/subscriptions/" + url.PathEscape(productID) + "/tokens/" + url.PathEscape(token) + ":acknowledge"
	return v.call(ctx, http.MethodPost, u, []byte("{}"), nil)
}

func (v *Verifier) call(ctx context.Context, method, u string, body []byte, out any) error {
	access, err := v.accessToken(ctx)
	if err != nil {
		return err
	}
	var rd io.Reader
	if body != nil {
		rd = strings.NewReader(string(body))
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := v.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	switch {
	case res.StatusCode == http.StatusOK || res.StatusCode == http.StatusNoContent:
	case res.StatusCode == http.StatusNotFound, res.StatusCode == http.StatusGone,
		res.StatusCode == http.StatusBadRequest && strings.Contains(string(b), "invalid"):
		return ErrNotFound
	default:
		if res.StatusCode == http.StatusUnauthorized {
			v.mu.Lock()
			v.access = ""
			v.mu.Unlock()
		}
		msg := string(b)
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return fmt.Errorf("Google Play %d %s", res.StatusCode, msg)
	}
	if out == nil || len(b) == 0 {
		return nil
	}
	return json.Unmarshal(b, out)
}

func (v *Verifier) accessToken(ctx context.Context) (string, error) {
	v.mu.Lock()
	if v.access != "" && v.now().Before(v.accessExp) {
		a := v.access
		v.mu.Unlock()
		return a, nil
	}
	v.mu.Unlock()

	now := v.now()
	enc := base64.RawURLEncoding
	head, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{
		"iss": v.email, "scope": "https://www.googleapis.com/auth/androidpublisher",
		"aud": v.tokenURL, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	unsigned := enc.EncodeToString(head) + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(unsigned))
	sig, err := rsa.SignPKCS1v15(rand.Reader, v.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {unsigned + "." + enc.EncodeToString(sig)},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := v.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 16384)).Decode(&tok); err != nil {
		return "", fmt.Errorf("token de Google: %w", err)
	}
	if res.StatusCode != http.StatusOK || tok.AccessToken == "" {
		return "", fmt.Errorf("token de Google %d: %s %s", res.StatusCode, tok.Error, tok.Description)
	}
	if tok.ExpiresIn <= 0 {
		tok.ExpiresIn = 3600
	}
	v.mu.Lock()
	v.access = tok.AccessToken
	v.accessExp = now.Add(time.Duration(tok.ExpiresIn)*time.Second - 2*time.Minute)
	v.mu.Unlock()
	return tok.AccessToken, nil
}

// NewFake crea un verificador contra un servidor de pruebas (tests).
func NewFake(credentials, pkg, baseURL, tokenURL string) (*Verifier, error) {
	v, err := New(credentials, pkg)
	if err != nil {
		return nil, err
	}
	v.baseURL, v.tokenURL = baseURL, tokenURL
	return v, nil
}
