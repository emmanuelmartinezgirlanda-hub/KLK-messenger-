package push

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
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

func testServiceAccount(t *testing.T, tokenURL string) (*rsa.PrivateKey, string) {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	b, _ := json.Marshal(map[string]string{
		"type": "service_account", "project_id": "klk-prueba", "client_email": "fcm@klk-prueba.iam.gserviceaccount.com",
		"private_key": pemKey, "token_uri": tokenURL,
	})
	return k, string(b)
}

func TestParseServiceAccount(t *testing.T) {
	_, js := testServiceAccount(t, "https://oauth2.googleapis.com/token")
	for _, in := range []string{js, base64.StdEncoding.EncodeToString([]byte(js)), "  " + js + "\n"} {
		sa, err := ParseServiceAccount(in)
		if err != nil || sa.ProjectID != "klk-prueba" {
			t.Fatalf("%v %+v", err, sa)
		}
	}
	if _, err := ParseServiceAccount("basura"); err == nil {
		t.Fatal("debería rechazar basura")
	}
	if _, err := NewFCM(`{"project_id":"x","client_email":"y","private_key":"no"}`, nil); err == nil {
		t.Fatal("debería rechazar una clave inválida")
	}
}

func TestFCM(t *testing.T) {
	st := store.NewMemory()
	ctx := context.Background()
	d, err := st.RegisterPrimary(ctx, store.RegisterParams{Phone: "+18095550002", RegistrationID: 1,
		IdentityKey: []byte("k"), TokenHash: []byte("h")})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetPushToken(ctx, d.AccountID, 1, store.PushToken{Platform: "fcm", Token: "tok:ABC_123", Lang: "es"}); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var pub *rsa.PublicKey
	tokenCalls, sends := 0, []map[string]any{}
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/token":
			tokenCalls++
			_ = r.ParseForm()
			parts := strings.Split(r.Form.Get("assertion"), ".")
			sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
			sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" ||
				rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.Write([]byte(`{"access_token":"ya29.prueba","expires_in":3600}`))
		case "/v1/projects/klk-prueba/messages:send":
			if r.Header.Get("Authorization") != "Bearer ya29.prueba" {
				t.Errorf("auth: %s", r.Header.Get("Authorization"))
			}
			var b map[string]any
			_ = json.NewDecoder(r.Body).Decode(&b)
			sends = append(sends, b)
			w.WriteHeader(status)
			if status != http.StatusOK {
				w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
			}
		default:
			t.Errorf("ruta %s", r.URL.Path)
		}
	}))
	defer srv.Close()

	k, js := testServiceAccount(t, srv.URL+"/token")
	pub = &k.PublicKey
	f, err := NewFCM(js, st)
	if err != nil {
		t.Fatal(err)
	}
	f.sendURL = srv.URL + "/v1/projects/klk-prueba/messages:send"

	wait := func(n int) {
		for i := 0; i < 300; i++ {
			mu.Lock()
			l := len(sends)
			mu.Unlock()
			if l >= n {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("no llegaron %d avisos", n)
	}

	// Un iPhone (apns) no lo toca FCM.
	Multi{f}.Notify(ctx, d.AccountID, 1)
	wait(1)
	mu.Lock()
	msg := sends[0]["message"].(map[string]any)
	if msg["token"] != "tok:ABC_123" || msg["notification"].(map[string]any)["body"] != "Tienes un mensaje nuevo" {
		t.Fatalf("mensaje: %v", msg)
	}
	status = http.StatusNotFound
	mu.Unlock()

	// Token caducado → se borra. El token de Google se reutiliza.
	f.now = func() time.Time { return time.Now().Add(time.Minute) }
	f.Notify(ctx, d.AccountID, 1)
	wait(2)
	for i := 0; i < 300; i++ {
		if _, err := st.GetPushToken(ctx, d.AccountID, 1); err == store.ErrNotFound {
			mu.Lock()
			defer mu.Unlock()
			if tokenCalls != 1 {
				t.Fatalf("pidió el token de Google %d veces", tokenCalls)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("el token caducado no se borró")
}
