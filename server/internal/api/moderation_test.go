package api_test

import (
	"net/http/httptest"
	"testing"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"

	"github.com/klk-app/klk-server/internal/store"
)

// Apple 1.2: filtro de palabras en lo público y bloquear avisa al equipo.
func TestModeracion(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550301", 1)
	luis := e.register("+18095550302", 2)
	e.do("PUT", "/v1/gente/me", ana.token, map[string]any{"name": "Ana", "rules": true}, nil)

	if s := e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "eres un pendejo"}, nil); s != 400 {
		t.Fatalf("publicación ofensiva: %d", s)
	}
	if s := e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "Vendo cartera de cuero"}, nil); s != 201 && s != 200 {
		t.Fatalf("publicación normal: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/me", ana.token, map[string]any{"name": "Hijo de puta"}, nil); s != 400 {
		t.Fatalf("nombre ofensivo: %d", s)
	}
	if s := e.do("PUT", "/v1/account/username", ana.token, map[string]any{"username": "puta.madre"}, nil); s != 400 {
		t.Fatalf("usuario ofensivo: %d", s)
	}

	// Bloquear en los chats y en Mi Gente deja aviso en el panel.
	if s := e.do("POST", "/v1/blocks/"+luis.accountID, ana.token, nil, nil); s != 204 {
		t.Fatalf("aviso de bloqueo: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/blocks/"+luis.accountID, ana.token, nil, nil); s != 204 {
		t.Fatalf("bloqueo Mi Gente: %d", s)
	}
	var reps struct {
		Reports []store.ReportView `json:"reports"`
	}
	e.do("GET", "/admin/api/reports", adminTok, nil, &reps)
	if len(reps.Reports) != 2 || reps.Reports[0].Reason != "bloqueo" {
		t.Fatalf("avisos de bloqueo: %+v", reps.Reports)
	}
}

func TestAdminServices(t *testing.T) {
	e := newAdminEnv(t)
	var out struct {
		Checks []struct {
			Name string `json:"name"`
			OK   bool   `json:"ok"`
		} `json:"checks"`
	}
	if s := e.do("GET", "/admin/api/services", adminTok, nil, &out); s != 200 || len(out.Checks) == 0 || !out.Checks[0].OK {
		t.Fatalf("servicios: %d %+v", s, out)
	}
	if s := e.do("GET", "/admin/api/services", "mala", nil, nil); s != 401 {
		t.Fatalf("sin clave: %d", s)
	}
}

func TestFundadores(t *testing.T) {
	e := newEnv(t)
	e.srv.Close()
	s := api.New(e.st, auth.NewOTP(e.sms), relay.NewHub(e.st, relay.NoopPusher{}))
	s.FoundersMax = 2
	e.srv = httptest.NewServer(s.Routes())
	t.Cleanup(e.srv.Close)
	a := e.register("+18095550401", 1)
	b := e.register("+18095550402", 2)
	c := e.register("+18095550403", 3)
	var v struct {
		Active bool `json:"active"`
	}
	for _, x := range []struct {
		tok  string
		want bool
	}{{a.token, true}, {b.token, true}, {c.token, false}} {
		v.Active = false
		e.do("GET", "/v1/plus", x.tok, nil, &v)
		if v.Active != x.want {
			t.Fatalf("plus %v, quería %v", v.Active, x.want)
		}
	}
}
