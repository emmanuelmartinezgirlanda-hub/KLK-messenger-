package auth

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
