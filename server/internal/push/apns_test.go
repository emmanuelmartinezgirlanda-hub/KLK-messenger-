package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

func testKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	return k, string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestJWTValido(t *testing.T) {
	k, p8 := testKey(t)
	// Render a veces guarda los saltos de línea como "\n" literales.
	for _, in := range []string{p8, strings.ReplaceAll(p8, "\n", `\n`)} {
		key, err := parseP8(in)
		if err != nil {
			t.Fatal(err)
		}
		tok, err := signJWT(key, "ABC123DEFG", "TEAM123456", time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if !verifyJWT(&k.PublicKey, tok) {
			t.Fatal("firma ES256 inválida")
		}
	}
	if _, err := parseP8("basura"); err == nil {
		t.Fatal("debería rechazar una clave inválida")
	}
}

func TestAvisoYTokenCaducado(t *testing.T) {
	_, p8 := testKey(t)
	st := store.NewMemory()
	ctx := context.Background()
	d, err := st.RegisterPrimary(ctx, store.RegisterParams{Phone: "+18095550001", RegistrationID: 1,
		IdentityKey: []byte("k"), TokenHash: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetPushToken(ctx, d.AccountID, 1, store.PushToken{Platform: "apns", Token: "abc", Lang: "en"}); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var got []map[string]any
	var headers http.Header
	status := http.StatusOK
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path != "/3/device/abc" {
			t.Errorf("ruta %s", r.URL.Path)
		}
		headers = r.Header.Clone()
		var b map[string]any
		_ = json.NewDecoder(r.Body).Decode(&b)
		got = append(got, b)
		w.WriteHeader(status)
		if status != http.StatusOK {
			w.Write([]byte(`{"reason":"Unregistered"}`))
		}
	}))
	defer srv.Close()

	a, err := NewAPNs(Config{KeyPEM: p8, KeyID: "ABC123DEFG", TeamID: "TEAM123456", Topic: "com.klkapp.klk"}, st)
	if err != nil {
		t.Fatal(err)
	}
	a.host, a.client = srv.URL, srv.Client()

	wait := func(n int) {
		for i := 0; i < 200; i++ {
			mu.Lock()
			l := len(got)
			mu.Unlock()
			if l >= n {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("no llegaron %d avisos", n)
	}

	a.Notify(ctx, d.AccountID, 1)
	wait(1)
	mu.Lock()
	aps := got[0]["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["body"] != "You have a new message" {
		t.Fatalf("texto: %v", alert["body"])
	}
	if headers.Get("apns-topic") != "com.klkapp.klk" || !strings.HasPrefix(headers.Get("authorization"), "bearer ") {
		t.Fatalf("cabeceras: %v", headers)
	}
	status = http.StatusGone
	mu.Unlock()

	// Seguido: se salta (no saturar). Pasado el hueco, Apple dice que el token ya no vale y se borra.
	a.Notify(ctx, d.AccountID, 1)
	time.Sleep(50 * time.Millisecond)
	a.now = func() time.Time { return time.Now().Add(time.Minute) }
	a.Notify(ctx, d.AccountID, 1)
	wait(2)
	for i := 0; i < 200; i++ {
		if _, err := st.GetPushToken(ctx, d.AccountID, 1); err == store.ErrNotFound {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("el token caducado no se borró")
}
