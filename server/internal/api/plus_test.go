package api_test

import (
	"net/http/httptest"
	"testing"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
)

func TestKLKPlus(t *testing.T) {
	e := newEnv(t)
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	s.PlusCodes = api.ParsePlusCodes(" duenoklk2026 , PRUEBA30:30, x ")
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	ana := e.register("+18095550201", 1)

	var v struct {
		Active bool    `json:"active"`
		Until  *string `json:"until"`
	}
	if s := e.do("GET", "/v1/plus", ana.token, nil, &v); s != 200 || v.Active {
		t.Fatalf("al principio sin Plus: %d %+v", s, v)
	}
	if s := e.do("POST", "/v1/plus/redeem", ana.token, map[string]string{"code": "malo123"}, nil); s != 400 {
		t.Fatalf("código malo: %d", s)
	}
	if s := e.do("POST", "/v1/plus/redeem", ana.token, map[string]string{"code": "DuenoKLK2026"}, &v); s != 200 || !v.Active {
		t.Fatalf("código del dueño: %d %+v", s, v)
	}
	v.Active = false
	if s := e.do("GET", "/v1/plus", ana.token, nil, &v); s != 200 || !v.Active || v.Until == nil {
		t.Fatalf("Plus activo: %d %+v", s, v)
	}
	if got := api.ParsePlusCodes("ab, ABCDEF:7"); len(got) != 1 || got[0].Days != 7 {
		t.Fatalf("códigos: %+v", got)
	}
}
