package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeStore struct {
	mu      sync.Mutex
	tokens  map[string]string
	dropped []string
}

func (f *fakeStore) PushToken(_ context.Context, acc string, _ int) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.tokens[acc], nil
}

func (f *fakeStore) DropPushToken(_ context.Context, t string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.dropped = append(f.dropped, t)
	return nil
}

func newKeyPEM(t *testing.T) (string, *ecdsa.PrivateKey) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), k
}

func TestParseKeyFormats(t *testing.T) {
	p, _ := newKeyPEM(t)
	if _, err := ParseKey(p); err != nil {
		t.Fatalf("PEM normal: %v", err)
	}
	if _, err := ParseKey(strings.ReplaceAll(p, "\n", `\n`)); err != nil {
		t.Fatalf("PEM con \\n como texto: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(p), "\n")
	if _, err := ParseKey(strings.Join(lines[1:len(lines)-1], "")); err != nil {
		t.Fatalf("solo base64: %v", err)
	}
	if _, err := ParseKey("basura"); err == nil {
		t.Fatal("debería fallar con una clave inválida")
	}
}

type got struct {
	path, auth, topic, pushType string
	body                        map[string]any
}

func TestNotifySendsAndDropsDeadTokens(t *testing.T) {
	keyPEM, key := newKeyPEM(t)
	reqs := make(chan got, 4)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		var b map[string]any
		_ = json.Unmarshal(data, &b)
		reqs <- got{r.URL.Path, r.Header.Get("authorization"), r.Header.Get("apns-topic"), r.Header.Get("apns-push-type"), b}
		if strings.HasSuffix(r.URL.Path, "/muerto") {
			w.WriteHeader(http.StatusGone)
			w.Write([]byte(`{"reason":"Unregistered"}`))
		}
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()

	st := &fakeStore{tokens: map[string]string{"ana": "vivo", "luis": "muerto"}}
	a, err := New(Config{KeyPEM: keyPEM, KeyID: "ABC123DEFG", TeamID: "TEAM123456", Topic: "com.klkapp.klk", Host: srv.URL}, st)
	if err != nil {
		t.Fatal(err)
	}
	a.client = srv.Client()

	a.Notify(context.Background(), "ana", 1)
	r := <-reqs
	if r.path != "/3/device/vivo" || r.topic != "com.klkapp.klk" || r.pushType != "alert" {
		t.Fatalf("petición inesperada: %+v", r)
	}
	if body, _ := json.Marshal(r.body); !strings.Contains(string(body), "Tienes un mensaje nuevo") {
		t.Fatalf("cuerpo: %s", body)
	}
	checkJWT(t, strings.TrimPrefix(r.auth, "bearer "), &key.PublicKey)

	// Un segundo aviso inmediato al mismo iPhone no se envía (anti-spam).
	a.Notify(context.Background(), "ana", 1)
	// Un token muerto se borra.
	a.Notify(context.Background(), "luis", 1)
	r = <-reqs
	if r.path != "/3/device/muerto" {
		t.Fatalf("se envió un aviso repetido: %+v", r)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		st.mu.Lock()
		n := len(st.dropped)
		st.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no se borró el token muerto")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Sin token no se envía nada.
	a.Notify(context.Background(), "nadie", 1)
	select {
	case r := <-reqs:
		t.Fatalf("no debería enviar: %+v", r)
	case <-time.After(200 * time.Millisecond):
	}
}

func checkJWT(t *testing.T, jwt string, pub *ecdsa.PublicKey) {
	t.Helper()
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT mal formado: %q", jwt)
	}
	enc := base64.RawURLEncoding
	var h map[string]string
	hb, _ := enc.DecodeString(parts[0])
	_ = json.Unmarshal(hb, &h)
	if h["alg"] != "ES256" || h["kid"] != "ABC123DEFG" {
		t.Fatalf("cabecera: %v", h)
	}
	var c map[string]any
	cb, _ := enc.DecodeString(parts[1])
	_ = json.Unmarshal(cb, &c)
	if c["iss"] != "TEAM123456" {
		t.Fatalf("claims: %v", c)
	}
	sig, _ := enc.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("firma de %d bytes", len(sig))
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, sum[:], r, s) {
		t.Fatal("firma del JWT no válida")
	}
}
