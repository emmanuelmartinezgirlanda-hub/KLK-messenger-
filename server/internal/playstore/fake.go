package playstore

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"
)

// FakeSub es una suscripción en el Google Play de pruebas.
type FakeSub struct {
	Product, Account, State string
	Expires                 time.Time
	Acked                   bool
}

// FakeServer imita la API de Google Play (y el token de OAuth) para los tests.
type FakeServer struct {
	*httptest.Server
	Credentials string

	mu   sync.Mutex
	Subs map[string]*FakeSub // por purchase token
}

// NewFakeServer arranca el Google Play de pruebas con su cuenta de servicio.
func NewFakeServer() *FakeServer {
	f := &FakeServer{Subs: map[string]*FakeSub{}}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	b, _ := json.Marshal(map[string]string{
		"client_email": "play@klk-prueba.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"token_uri":    f.URL + "/token",
	})
	f.Credentials = string(b)
	return f
}

// Verifier conectado a este servidor.
func (f *FakeServer) Verifier() *Verifier {
	v, err := NewFake(f.Credentials, "com.klkapp.klk", f.URL, f.URL+"/token")
	if err != nil {
		panic(err)
	}
	return v
}

// Add mete una suscripción.
func (f *FakeServer) Add(token string, s FakeSub) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Subs[token] = &s
}

// Acked dice si la compra se confirmó.
func (f *FakeServer) Acked(token string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	s := f.Subs[token]
	return s != nil && s.Acked
}

func (f *FakeServer) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.URL.Path == "/token" {
		w.Write([]byte(`{"access_token":"ya29.play","expires_in":3600}`))
		return
	}
	if r.Header.Get("Authorization") != "Bearer ya29.play" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	const pre = "/androidpublisher/v3/applications/com.klkapp.klk/purchases/"
	p := r.URL.Path
	switch {
	case r.Method == http.MethodGet && strings.HasPrefix(p, pre+"subscriptionsv2/tokens/"):
		s := f.Subs[strings.TrimPrefix(p, pre+"subscriptionsv2/tokens/")]
		if s == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		ack := "ACKNOWLEDGEMENT_STATE_PENDING"
		if s.Acked {
			ack = "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
		}
		out := map[string]any{
			"subscriptionState":    s.State,
			"acknowledgementState": ack,
			"lineItems":            []map[string]string{{"productId": s.Product, "expiryTime": s.Expires.UTC().Format(time.RFC3339Nano)}},
		}
		if s.Account != "" {
			out["externalAccountIdentifiers"] = map[string]string{"obfuscatedExternalAccountId": s.Account}
		}
		json.NewEncoder(w).Encode(out)
	case r.Method == http.MethodPost && strings.HasPrefix(p, pre+"subscriptions/") && strings.HasSuffix(p, ":acknowledge"):
		parts := strings.Split(strings.TrimSuffix(strings.TrimPrefix(p, pre+"subscriptions/"), ":acknowledge"), "/tokens/")
		if len(parts) != 2 || f.Subs[parts[1]] == nil || f.Subs[parts[1]].Product != parts[0] {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f.Subs[parts[1]].Acked = true
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}
