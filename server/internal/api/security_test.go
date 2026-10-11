package api_test

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
)

// newGuardedEnv crea un servidor con límites de SMS y un reloj que se puede adelantar.
func newGuardedEnv(t *testing.T, guard *api.SMSGuard) (*env, *time.Time) {
	e := newEnv(t)
	e.srv.Close()
	now := time.Now()
	otp := auth.NewOTP(e.sms)
	otp.SetNow(func() time.Time { return now })
	s := api.New(e.st, otp, relay.NewHub(e.st, relay.NoopPusher{}))
	s.SMS = guard
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	return e, &now
}

func TestRegistrationPin(t *testing.T) {
	e, now := newGuardedEnv(t, nil)
	a := e.register("+18095550101", 1)

	// PIN con letras o corto: no.
	if s := e.do("PUT", "/v1/account/pin", a.token, map[string]string{"pin": "12ab56"}, nil); s != 400 {
		t.Fatalf("pin malo: %d", s)
	}
	if s := e.do("PUT", "/v1/account/pin", a.token, map[string]string{"pin": "246810"}, nil); s != 204 {
		t.Fatalf("poner pin: %d", s)
	}
	var st struct {
		Enabled bool `json:"enabled"`
	}
	e.do("GET", "/v1/account/pin", a.token, nil, &st)
	if !st.Enabled {
		t.Fatal("el PIN debería estar activado")
	}

	// Alguien con la SIM intenta registrarse en otro móvil.
	*now = now.Add(2 * time.Minute)
	if s := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": "+18095550101"}, nil); s != 204 {
		t.Fatalf("pedir código: %d", s)
	}
	body := map[string]any{"phone": "+18095550101", "code": e.sms.code("+18095550101"), "deviceName": "ladrón",
		"registrationId": 99, "identityKey": pubKey(9)}
	var out struct {
		Code     string `json:"code"`
		RegToken string `json:"regToken"`
		Left     int    `json:"attemptsLeft"`
		Token    string `json:"token"`
	}
	if s := e.do("POST", "/v1/verification/verify", "", body, &out); s != 423 || out.Code != "pin_required" || out.RegToken == "" {
		t.Fatalf("debería pedir PIN: %d %+v", s, out)
	}
	tok := out.RegToken
	// PIN equivocado: no entra y le quedan 9 intentos.
	body = map[string]any{"phone": "+18095550101", "regToken": tok, "pin": "111111", "deviceName": "ladrón",
		"registrationId": 99, "identityKey": pubKey(9)}
	out = struct {
		Code     string `json:"code"`
		RegToken string `json:"regToken"`
		Left     int    `json:"attemptsLeft"`
		Token    string `json:"token"`
	}{}
	if s := e.do("POST", "/v1/verification/verify", "", body, &out); s != 423 || out.Code != "bad_pin" || out.Left != 9 {
		t.Fatalf("pin equivocado: %d %+v", s, out)
	}
	// La sesión antigua sigue viva.
	if s := e.do("GET", "/v1/keys/count", a.token, nil, nil); s != 200 {
		t.Fatalf("la cuenta no debería haberse perdido: %d", s)
	}
	// Con el PIN bueno sí entra.
	body["pin"] = "246810"
	if s := e.do("POST", "/v1/verification/verify", "", body, &out); s != 200 || out.Token == "" {
		t.Fatalf("pin bueno: %d %+v", s, out)
	}
	// Un token inventado no sirve.
	body["regToken"] = "inventado"
	if s := e.do("POST", "/v1/verification/verify", "", body, nil); s != 403 {
		t.Fatalf("token inventado: %d", s)
	}
}

func TestSMSGuard(t *testing.T) {
	e, now := newGuardedEnv(t, &api.SMSGuard{Countries: []string{"+34", "+1"}, DailyMax: 3, CountryMax: 2, PerIPMax: 100})
	req := func(phone string) int {
		*now = now.Add(2 * time.Minute)
		return e.do("POST", "/v1/verification/request", "", map[string]string{"phone": phone}, nil)
	}
	if s := req("+5511999998888"); s != 403 {
		t.Fatalf("país no permitido: %d", s)
	}
	if req("+34600000001") != 204 || req("+34600000002") != 204 {
		t.Fatal("los dos primeros a España deberían salir")
	}
	if s := req("+34600000003"); s != 429 {
		t.Fatalf("tope por país: %d", s)
	}
	if s := req("+12125550101"); s != 204 {
		t.Fatalf("otro país aún puede: %d", s)
	}
	if s := req("+12125550102"); s != 429 {
		t.Fatalf("tope total: %d", s)
	}
}

func TestSMSGuardPerIP(t *testing.T) {
	e, now := newGuardedEnv(t, &api.SMSGuard{PerIPMax: 2})
	for i, want := range []int{204, 204, 429} {
		*now = now.Add(2 * time.Minute)
		phone := []string{"+34611111111", "+34622222222", "+34633333333"}[i]
		if s := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": phone}, nil); s != want {
			t.Fatalf("petición %d: %d, quería %d", i, s, want)
		}
	}
}
