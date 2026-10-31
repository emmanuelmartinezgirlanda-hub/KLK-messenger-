package api_test

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/appstore"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/playstore"
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

func TestKLKPlusApple(t *testing.T) {
	e := newEnv(t)
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	signer := appstore.NewTestSigner()
	s.Apple = appstore.NewWithRoots(signer.Roots)
	s.AppleBundleID = "com.klkapp.klk"
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	ana := e.register("+18095550301", 1)
	luis := e.register("+18095550302", 1)

	exp := time.Now().Add(30 * 24 * time.Hour)
	buy := func(otid, bundle string, until time.Time, token string) string {
		return signer.Sign(appstore.Transaction{OriginalTransactionID: otid, BundleID: bundle,
			ProductID: "klk.plus.mensual", ExpiresDate: until.UnixMilli(), AppAccountToken: token})
	}
	var v struct {
		Active bool `json:"active"`
	}
	body := func(j ...string) map[string]any { return map[string]any{"jws": j} }
	if st := e.do("POST", "/v1/plus/apple", ana.token, body(buy("1", "otra.app", exp, "")), nil); st != 400 {
		t.Fatalf("otra app: %d", st)
	}
	if st := e.do("POST", "/v1/plus/apple", ana.token, body(buy("1", "com.klkapp.klk", time.Now().Add(-time.Hour), "")), nil); st != 400 {
		t.Fatalf("caducada: %d", st)
	}
	if st := e.do("POST", "/v1/plus/apple", ana.token, body(buy("1", "com.klkapp.klk", exp, luis.accountID)), nil); st != 409 {
		t.Fatalf("comprada para otra cuenta: %d", st)
	}
	if st := e.do("POST", "/v1/plus/apple", ana.token, body(buy("1", "com.klkapp.klk", exp, ana.accountID)), &v); st != 200 || !v.Active {
		t.Fatalf("compra buena: %d %+v", st, v)
	}
	// La misma suscripción no se puede usar en otra cuenta.
	if st := e.do("POST", "/v1/plus/apple", luis.token, body(buy("1", "com.klkapp.klk", exp, "")), nil); st != 409 {
		t.Fatalf("compartir suscripción: %d", st)
	}
	v.Active = false
	if st := e.do("GET", "/v1/plus", ana.token, nil, &v); st != 200 || !v.Active {
		t.Fatalf("Plus activo: %d", st)
	}
}

func TestKLKPlusGoogle(t *testing.T) {
	e := newEnv(t)
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	gp := playstore.NewFakeServer()
	t.Cleanup(gp.Close)
	s.Play = gp.Verifier()
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	ana := e.register("+18095550311", 1)
	luis := e.register("+18095550312", 1)

	exp := time.Now().Add(30 * 24 * time.Hour)
	gp.Add("tok-otra-app", playstore.FakeSub{Product: "otra.cosa", State: "SUBSCRIPTION_STATE_ACTIVE", Expires: exp})
	gp.Add("tok-caducada", playstore.FakeSub{Product: "klk.plus.mensual", State: "SUBSCRIPTION_STATE_EXPIRED", Expires: time.Now().Add(-time.Hour)})
	gp.Add("tok-pendiente", playstore.FakeSub{Product: "klk.plus.mensual", State: "SUBSCRIPTION_STATE_PENDING", Expires: exp})
	gp.Add("tok-de-luis", playstore.FakeSub{Product: "klk.plus.mensual", Account: luis.accountID, State: "SUBSCRIPTION_STATE_ACTIVE", Expires: exp})
	gp.Add("tok-ana", playstore.FakeSub{Product: "klk.plus.anual", Account: ana.accountID, State: "SUBSCRIPTION_STATE_ACTIVE", Expires: exp})

	var v struct {
		Active bool `json:"active"`
	}
	body := func(t ...string) map[string]any { return map[string]any{"tokens": t} }
	if st := e.do("POST", "/v1/plus/google", ana.token, body("inventado", "tok-otra-app", "tok-caducada", "tok-pendiente"), nil); st != 400 {
		t.Fatalf("compras que no valen: %d", st)
	}
	if st := e.do("POST", "/v1/plus/google", ana.token, body("tok-de-luis"), nil); st != 409 {
		t.Fatalf("comprada por otra cuenta: %d", st)
	}
	if st := e.do("POST", "/v1/plus/google", ana.token, body("inventado", "tok-ana"), &v); st != 200 || !v.Active {
		t.Fatalf("compra buena: %d %+v", st, v)
	}
	if !gp.Acked("tok-ana") {
		t.Fatal("la compra no se confirmó en Google")
	}
	// La misma suscripción no se puede usar en otra cuenta.
	if st := e.do("POST", "/v1/plus/google", luis.token, body("tok-ana"), nil); st != 409 {
		t.Fatalf("compartir suscripción: %d", st)
	}
	// Cancelada pero aún pagada: sigue valiendo.
	gp.Add("tok-ana", playstore.FakeSub{Product: "klk.plus.anual", Account: ana.accountID, State: "SUBSCRIPTION_STATE_CANCELED", Expires: exp, Acked: true})
	if st := e.do("POST", "/v1/plus/google", ana.token, body("tok-ana"), &v); st != 200 || !v.Active {
		t.Fatalf("cancelada pero pagada: %d", st)
	}
	v.Active = false
	if st := e.do("GET", "/v1/plus", ana.token, nil, &v); st != 200 || !v.Active {
		t.Fatalf("Plus activo: %d", st)
	}
}
