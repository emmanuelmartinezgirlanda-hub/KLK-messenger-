package api_test

import (
	"net/http/httptest"
	"testing"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
)

// El revisor de Apple escribió el número con el +1 repetido: tiene que entrar igual,
// sin SMS y sin gastar los límites antiabuso de su conexión.
func TestReviewPhoneDuplicatedPrefix(t *testing.T) {
	e := newEnv(t)
	otp := auth.NewOTP(e.sms)
	otp.SetReview([]string{"+12025550147"}, "123456")
	s := api.New(e.st, otp, relay.NewHub(e.st, relay.NoopPusher{}))
	s.SMS = &api.SMSGuard{PerIPMax: 1}
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	for i, p := range []string{"+112025550147", "+1 (202) 555-0147", "+12025550147", "+112025550147"} {
		if st := e.do("POST", "/v1/verification/request", "", map[string]string{"phone": p}, nil); st != 204 {
			t.Fatalf("intento %d (%s): %d", i, p, st)
		}
	}
}
