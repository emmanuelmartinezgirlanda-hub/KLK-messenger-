package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestTwilioSender(t *testing.T) {
	var got struct{ path, user, to, from, body string }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		got.path = r.URL.Path
		got.user, _, _ = r.BasicAuth()
		got.to, got.from, got.body = r.Form.Get("To"), r.Form.Get("From"), r.Form.Get("Body")
		w.WriteHeader(201)
	}))
	defer srv.Close()

	s := TwilioSender{AccountSID: "AC123", AuthToken: "tok", From: "+15005550006", BaseURL: srv.URL}
	if err := s.Send("+18095551234", "Tu código de KLK es 123456."); err != nil {
		t.Fatal(err)
	}
	if got.path != "/2010-04-01/Accounts/AC123/Messages.json" || got.user != "AC123" ||
		got.to != "+18095551234" || got.from != "+15005550006" || !strings.Contains(got.body, "123456") {
		t.Fatalf("petición inesperada: %+v", got)
	}
}

func TestTwilioError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"message":"invalid number"}`, 400)
	}))
	defer srv.Close()
	err := TwilioSender{AccountSID: "AC1", AuthToken: "x", From: "MG1", BaseURL: srv.URL}.Send("+1", "hola")
	if err == nil || !strings.Contains(err.Error(), "400") {
		t.Fatalf("esperaba error 400, llegó %v", err)
	}
}

func TestReviewPhones(t *testing.T) {
	sent := 0
	o := NewOTP(senderFunc(func(string, string) error { sent++; return nil }))
	o.SetReview([]string{"+12025550147"}, "246810")
	if err := o.Request("+12025550147"); err != nil || sent != 0 {
		t.Fatalf("revisión: err=%v sms=%d", err, sent)
	}
	if o.Verify("+12025550147", "000000") == nil {
		t.Fatal("código malo aceptado")
	}
	if err := o.Verify("+12025550147", "246810"); err != nil {
		t.Fatal(err)
	}
	if err := o.Verify("+12025550147", "246810"); err != nil {
		t.Fatal("el código fijo debe valer siempre")
	}
	// Otros números siguen igual.
	if err := o.Request("+34600000001"); err != nil || sent != 1 {
		t.Fatalf("normal: %v %d", err, sent)
	}
}

type senderFunc func(string, string) error

func (f senderFunc) Send(p, m string) error { return f(p, m) }

func TestReviewCodeLocksAfterFailures(t *testing.T) {
	o := NewOTP(LogSender{})
	o.SetReview([]string{"+12025550147"}, "123456")
	for i := 0; i < reviewMaxFails; i++ {
		if o.Verify("+12025550147", "000000") == nil {
			t.Fatal("aceptó un código malo")
		}
	}
	if o.Verify("+12025550147", "123456") == nil {
		t.Fatal("tras muchos fallos debería estar bloqueado aunque el código sea bueno")
	}
	later := time.Now().Add(2 * time.Hour)
	o.now = func() time.Time { return later }
	if err := o.Verify("+12025550147", "123456"); err != nil {
		t.Fatalf("pasada la hora debería entrar: %v", err)
	}
}
