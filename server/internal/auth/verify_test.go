package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeTwilio imita los dos endpoints de Twilio Verify que usamos.
func fakeTwilio(t *testing.T) (*httptest.Server, *sync.Map) {
	t.Helper()
	pending := &sync.Map{} // teléfono → código
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		if user != "AC123" || pass != "secreto" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/v2/Services/VA123/") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		r.ParseForm()
		to := r.Form.Get("To")
		switch {
		case strings.HasSuffix(r.URL.Path, "/Verifications"):
			if r.Form.Get("Channel") != "sms" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			pending.Store(to, "123456")
			w.WriteHeader(http.StatusCreated)
			json.NewEncoder(w).Encode(map[string]string{"status": "pending"})
		case strings.HasSuffix(r.URL.Path, "/VerificationCheck"):
			code, ok := pending.Load(to)
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			status := "pending"
			if code == r.Form.Get("Code") {
				status = "approved"
				pending.Delete(to)
			}
			json.NewEncoder(w).Encode(map[string]string{"status": status})
		}
	}))
	t.Cleanup(srv.Close)
	return srv, pending
}

func TestTwilioVerify(t *testing.T) {
	srv, _ := fakeTwilio(t)
	otp := NewRemoteOTP(TwilioVerify{AccountSID: "AC123", AuthToken: "secreto", ServiceSID: "VA123", BaseURL: srv.URL})
	phone := "+18095551234"

	if err := otp.Request("809"); !errors.Is(err, ErrInvalidPhone) {
		t.Fatalf("número inválido aceptado: %v", err)
	}
	if err := otp.Request(phone); err != nil {
		t.Fatal(err)
	}
	if err := otp.Request(phone); !errors.Is(err, ErrTooSoon) {
		t.Fatalf("debería pedir esperar: %v", err)
	}
	if err := otp.Verify(phone, "000000"); !errors.Is(err, ErrBadCode) {
		t.Fatalf("código malo aceptado: %v", err)
	}
	if err := otp.Verify(phone, "123456"); err != nil {
		t.Fatalf("código bueno rechazado: %v", err)
	}
	// Ya usado: Twilio devuelve 404.
	if err := otp.Verify(phone, "123456"); !errors.Is(err, ErrBadCode) {
		t.Fatalf("código reutilizado: %v", err)
	}
}

func TestTwilioVerifyCredencialesMalas(t *testing.T) {
	srv, _ := fakeTwilio(t)
	otp := NewRemoteOTP(TwilioVerify{AccountSID: "AC123", AuthToken: "mal", ServiceSID: "VA123", BaseURL: srv.URL})
	if err := otp.Request("+18095551234"); err == nil {
		t.Fatal("debería fallar con credenciales malas")
	}
	// Tras un fallo de envío se puede reintentar sin esperar.
	otp.remote = TwilioVerify{AccountSID: "AC123", AuthToken: "secreto", ServiceSID: "VA123", BaseURL: srv.URL}
	if err := otp.Request("+18095551234"); err != nil {
		t.Fatalf("reintento bloqueado: %v", err)
	}
}
