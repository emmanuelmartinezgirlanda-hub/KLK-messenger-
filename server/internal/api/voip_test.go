package api_test

import (
	"context"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/api"
	"github.com/klk-app/klk-server/internal/auth"
	"github.com/klk-app/klk-server/internal/relay"
	"github.com/klk-app/klk-server/internal/store"
)

type fakeRinger struct {
	fakePusher
	rmu   sync.Mutex
	rings []store.CallInvite
}

func (f *fakeRinger) Ring(_ context.Context, _ string, _ int, c store.CallInvite) {
	f.rmu.Lock()
	defer f.rmu.Unlock()
	f.rings = append(f.rings, c)
}

func (f *fakeRinger) ringCount() int {
	f.rmu.Lock()
	defer f.rmu.Unlock()
	return len(f.rings)
}

func TestLlamadaConMovilBloqueado(t *testing.T) {
	e := newEnv(t)
	p := &fakeRinger{fakePusher: fakePusher{hits: map[string]int{}}}
	hub := relay.NewHub(e.st, p)
	hub.SetAckWait(150 * time.Millisecond)
	e.srv = httptest.NewServer(api.New(e.st, auth.NewOTP(e.sms), hub).Routes())
	t.Cleanup(e.srv.Close)

	ana := e.register("+18095550111", 1)
	beto := e.register("+18095550112", 10)

	tok := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	if s := e.do("PUT", "/v1/voip-token", beto.token, map[string]string{"token": "malo"}, nil); s != 400 {
		t.Fatalf("token inválido: %d", s)
	}
	if s := e.do("PUT", "/v1/voip-token", beto.token, map[string]string{"token": tok}, nil); s != 204 {
		t.Fatalf("guardar token: %d", s)
	}
	if got, err := e.st.GetVoIPToken(context.Background(), beto.accountID, 1); err != nil || got != tok {
		t.Fatalf("token guardado: %q %v", got, err)
	}

	a := e.connect(ana)
	a.expect("synced")

	// Beto desconectado (iPhone bloqueado): la llamada suena al momento,
	// sin el aviso normal de "mensaje nuevo".
	a.send(sendFrame("c1", beto.accountID, "oferta", map[string]any{
		"push": "call", "call": map[string]any{"id": "llamada-1", "video": true}}))
	a.expect("sent")
	time.Sleep(50 * time.Millisecond)
	if n := p.ringCount(); n != 1 || p.rings[0].ID != "llamada-1" || !p.rings[0].Video || p.rings[0].From != ana.accountID {
		t.Fatalf("llamada con Beto desconectado: %+v", p.rings)
	}
	if n := p.count(beto.accountID); n != 0 {
		t.Fatalf("no debe mandar el aviso de mensaje: %d", n)
	}

	// Sin datos de la llamada: no suena.
	a.send(sendFrame("c2", beto.accountID, "x", map[string]any{"push": "call"}))
	a.expect("sent")
	time.Sleep(50 * time.Millisecond)
	if n := p.ringCount(); n != 1 {
		t.Fatalf("sin id no suena: %d", n)
	}

	// Borrar los avisos también borra el de llamadas.
	if s := e.do("DELETE", "/v1/push-token", beto.token, nil, nil); s != 204 {
		t.Fatalf("borrar: %d", s)
	}
	if _, err := e.st.GetVoIPToken(context.Background(), beto.accountID, 1); err != store.ErrNotFound {
		t.Fatalf("el token de llamadas sigue: %v", err)
	}
}
