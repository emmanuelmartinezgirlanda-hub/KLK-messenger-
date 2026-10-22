package api_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/turn"
)

func TestTurnEndpoint(t *testing.T) {
	cf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"iceServers":[{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}]}`))
	}))
	defer cf.Close()
	e := newEnv(t)
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	s.TURN = &turn.Cache{P: turn.Cloudflare{KeyID: "k", Token: "t", BaseURL: cf.URL}}
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	ana := e.register("+18095550301", 1)

	if st := e.do("GET", "/v1/turn", "", nil, nil); st != http.StatusUnauthorized {
		t.Fatalf("sin sesión: %d", st)
	}
	var out struct {
		ICEServers []turn.ICEServer `json:"iceServers"`
	}
	if st := e.do("GET", "/v1/turn", ana.token, nil, &out); st != 200 || len(out.ICEServers) != 2 || out.ICEServers[1].Credential != "c" {
		t.Fatalf("turn: %d %+v", st, out)
	}
}
